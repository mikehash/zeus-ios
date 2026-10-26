//! # Voice ② — the realtime session, auth-independent
//!
//! A two-way WebSocket session the phone drives across UniFFI: Swift pushes
//! frames in (`send_text` / `send_binary`), the socket's frames come back out
//! through a [`RealtimeSink`] callback. The socket lives in Rust per the
//! 2026-09-21 ruling (the crossing measured ~1000× under budget at 640–960 B
//! frames, so `AVAudioEngine` proximity does not earn a Swift reimplementation).
//!
//! ## What this module deliberately does NOT know
//!
//! **Who the provider is, and how it authenticates.** The auth arm — key on
//! the device vs. a server minting short-lived tokens — is an open owner
//! decision. Everything that depends on it is a *value passed in*:
//! [`RealtimeConnect`] carries the URL and the handshake headers verbatim. A
//! long-lived key, an ephemeral token, a query-string credential: all three
//! options arrive here as a URL + headers, so the provider wiring plugs in
//! later without this file changing.
//!
//! **The provider's envelope.** OpenAI Realtime and Gemini Live both carry
//! audio as base64 inside JSON text frames, each with its own event schema.
//! That schema is provider wiring and is held with it. This layer moves
//! frames, text and binary, in both directions, and nothing else.
//!
//! ## Contract the sink can rely on
//!
//! Exactly ONE terminal call — `on_closed` XOR `on_error` — per session, ever.
//! Reader and writer can both observe the end of a socket; the terminal latch
//! is what stops the phone seeing a close followed by an error for one event.
//! After the terminal call, `is_closed()` is true and every send is
//! `RealtimeError::Closed`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};

use crate::ZeusCore;
use tokio::sync::{mpsc, Notify};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

/// Outbound frames that may sit in the queue before `send_*` refuses.
///
/// At the realtime rate (~50 audio frames/s) this is ~5 s of backlog: long
/// enough to absorb a TLS stall, short enough that a socket which has stopped
/// draining surfaces as `QueueFull` instead of as unbounded memory growth on
/// the phone's audio thread.
pub const SEND_QUEUE_DEPTH: usize = 256;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RealtimeError {
    #[error("realtime URL rejected: {0}")]
    BadUrl(String),
    /// Carries the header NAME only. The value is very likely a credential
    /// (that is what the headers are for), and an error string ends up in
    /// logs and on screen.
    #[error("realtime header {0} is not a valid HTTP header")]
    BadHeader(String),
    #[error("realtime connect failed: {0}")]
    Connect(String),
    #[error("realtime session is closed")]
    Closed,
    #[error("realtime send queue is full — the socket is not draining")]
    QueueFull,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct RealtimeHeader {
    pub name: String,
    pub value: String,
}

/// Everything provider- and auth-specific, as data.
#[derive(uniffi::Record, Clone, Debug)]
pub struct RealtimeConnect {
    /// `ws://` or `wss://`. Any credential that rides the query string rides
    /// it here.
    pub url: String,
    /// Sent on the upgrade request verbatim, in order. Repeated names are
    /// appended, not collapsed.
    pub headers: Vec<RealtimeHeader>,
}

#[uniffi::export(callback_interface)]
pub trait RealtimeSink: Send + Sync + 'static {
    fn on_text(&self, frame: String);
    fn on_binary(&self, frame: Vec<u8>);
    /// Terminal. `code` is `None` when the socket ended without a close frame.
    fn on_closed(&self, code: Option<u16>, reason: String);
    /// Terminal.
    fn on_error(&self, message: String);
}

enum Outbound {
    Text(String),
    Binary(Vec<u8>),
}

/// The one-terminal-call latch, shared by reader and writer.
struct Terminal {
    sink: Arc<dyn RealtimeSink>,
    fired: AtomicBool,
}

impl Terminal {
    fn closed(&self, code: Option<u16>, reason: String) {
        if !self.fired.swap(true, Ordering::SeqCst) {
            self.sink.on_closed(code, reason);
        }
    }
    fn error(&self, message: String) {
        if !self.fired.swap(true, Ordering::SeqCst) {
            self.sink.on_error(message);
        }
    }
    fn is_fired(&self) -> bool {
        self.fired.load(Ordering::SeqCst)
    }
}

#[derive(uniffi::Object)]
pub struct RealtimeSession {
    tx: mpsc::Sender<Outbound>,
    close: Arc<Notify>,
    terminal: Arc<Terminal>,
}

impl RealtimeSession {
    fn push(&self, frame: Outbound) -> Result<(), RealtimeError> {
        if self.terminal.is_fired() {
            return Err(RealtimeError::Closed);
        }
        self.tx.try_send(frame).map_err(|e| match e {
            mpsc::error::TrySendError::Full(_) => RealtimeError::QueueFull,
            mpsc::error::TrySendError::Closed(_) => RealtimeError::Closed,
        })
    }
}

#[uniffi::export]
impl RealtimeSession {
    pub fn send_text(&self, frame: String) -> Result<(), RealtimeError> {
        self.push(Outbound::Text(frame))
    }

    pub fn send_binary(&self, frame: Vec<u8>) -> Result<(), RealtimeError> {
        self.push(Outbound::Binary(frame))
    }

    /// Start a normal close (1000). Not routed through the frame queue, so a
    /// full queue cannot swallow it. The terminal `on_closed` arrives when the
    /// peer answers the close.
    pub fn close(&self) {
        self.close.notify_one();
    }

    pub fn is_closed(&self) -> bool {
        self.terminal.is_fired()
    }
}

#[uniffi::export]
impl ZeusCore {
    /// Open a realtime session. Blocks for the handshake only; frames flow on
    /// the core's runtime afterwards.
    pub fn realtime_connect(
        &self,
        conn: RealtimeConnect,
        sink: Box<dyn RealtimeSink>,
    ) -> Result<Arc<RealtimeSession>, RealtimeError> {
        let sink: Arc<dyn RealtimeSink> = Arc::from(sink);
        self.rt.block_on(open(conn, sink)).map(Arc::new)
    }
}

/// Build the upgrade request. Split out so header handling is testable
/// without a socket.
fn build_request(
    conn: &RealtimeConnect,
) -> Result<tokio_tungstenite::tungstenite::handshake::client::Request, RealtimeError> {
    // `into_client_request` does NOT check the scheme — `https://` builds a
    // request and only fails later, inside connect, as a generic error.
    // Measured: the non-ws leg was red on exactly that. Refuse at the door.
    let lower = conn.url.to_ascii_lowercase();
    if !(lower.starts_with("ws://") || lower.starts_with("wss://")) {
        return Err(RealtimeError::BadUrl("scheme must be ws:// or wss://".into()));
    }
    let mut req = conn
        .url
        .as_str()
        .into_client_request()
        .map_err(|e| RealtimeError::BadUrl(e.to_string()))?;
    for h in &conn.headers {
        let name = HeaderName::from_bytes(h.name.as_bytes())
            .map_err(|_| RealtimeError::BadHeader(h.name.clone()))?;
        let value =
            HeaderValue::from_str(&h.value).map_err(|_| RealtimeError::BadHeader(h.name.clone()))?;
        req.headers_mut().append(name, value);
    }
    Ok(req)
}

/// Connect and spawn the two halves. Must run inside a tokio runtime (the
/// bridge calls it under `ZeusCore::rt.block_on`).
pub(crate) async fn open(
    conn: RealtimeConnect,
    sink: Arc<dyn RealtimeSink>,
) -> Result<RealtimeSession, RealtimeError> {
    let req = build_request(&conn)?;
    let (ws, _resp) = tokio_tungstenite::connect_async(req)
        .await
        .map_err(|e| RealtimeError::Connect(e.to_string()))?;
    let (mut write, mut read) = ws.split();

    let (tx, mut rx) = mpsc::channel::<Outbound>(SEND_QUEUE_DEPTH);
    let close = Arc::new(Notify::new());
    let terminal = Arc::new(Terminal { sink: sink.clone(), fired: AtomicBool::new(false) });

    // Writer: frames out, plus the close request. `biased` so a close is not
    // starved behind a queue that is still filling.
    {
        let close = close.clone();
        let terminal = terminal.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    biased;
                    _ = close.notified() => {
                        let frame = CloseFrame { code: CloseCode::Normal, reason: "".into() };
                        if let Err(e) = write.send(Message::Close(Some(frame))).await {
                            terminal.error(format!("realtime close failed: {e}"));
                        }
                        break;
                    }
                    next = rx.recv() => {
                        let msg = match next {
                            Some(Outbound::Text(t)) => Message::Text(t),
                            Some(Outbound::Binary(b)) => Message::Binary(b),
                            // Every session handle is gone: close politely.
                            None => {
                                let _ = write.send(Message::Close(None)).await;
                                break;
                            }
                        };
                        if let Err(e) = write.send(msg).await {
                            match e {
                                WsError::ConnectionClosed | WsError::AlreadyClosed => {
                                    terminal.closed(None, String::new())
                                }
                                other => terminal.error(format!("realtime send failed: {other}")),
                            }
                            break;
                        }
                    }
                }
            }
        });
    }

    // Reader: frames in. Ping/pong is answered inside tungstenite.
    {
        let terminal = terminal.clone();
        tokio::spawn(async move {
            while let Some(next) = read.next().await {
                match next {
                    Ok(Message::Text(t)) => sink.on_text(t),
                    Ok(Message::Binary(b)) => sink.on_binary(b),
                    Ok(Message::Close(frame)) => {
                        let (code, reason) = match frame {
                            Some(f) => (Some(u16::from(f.code)), f.reason.into_owned()),
                            None => (None, String::new()),
                        };
                        terminal.closed(code, reason);
                        return;
                    }
                    Ok(_) => {}
                    Err(WsError::ConnectionClosed) | Err(WsError::AlreadyClosed) => break,
                    Err(e) => {
                        terminal.error(format!("realtime receive failed: {e}"));
                        return;
                    }
                }
            }
            terminal.closed(None, String::new());
        });
    }

    Ok(RealtimeSession { tx, close, terminal })
}

#[cfg(test)]
mod tests {
    //! Every leg runs against a local `tokio-tungstenite` server on 127.0.0.1.
    //! No provider, no key, no spend: the subject is the transport, and a
    //! provider mock would only be testing the mock.

    use super::*;
    use std::time::Duration;
    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};

    #[derive(Debug, PartialEq)]
    enum Ev {
        Text(String),
        Binary(Vec<u8>),
        Closed(Option<u16>, String),
        Error(String),
    }

    struct Recorder(mpsc::UnboundedSender<Ev>);
    impl RealtimeSink for Recorder {
        fn on_text(&self, f: String) {
            let _ = self.0.send(Ev::Text(f));
        }
        fn on_binary(&self, f: Vec<u8>) {
            let _ = self.0.send(Ev::Binary(f));
        }
        fn on_closed(&self, c: Option<u16>, r: String) {
            let _ = self.0.send(Ev::Closed(c, r));
        }
        fn on_error(&self, m: String) {
            let _ = self.0.send(Ev::Error(m));
        }
    }

    fn recorder() -> (Arc<dyn RealtimeSink>, mpsc::UnboundedReceiver<Ev>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Recorder(tx)), rx)
    }

    async fn next(rx: &mut mpsc::UnboundedReceiver<Ev>) -> Ev {
        tokio::time::timeout(Duration::from_secs(5), rx.recv())
            .await
            .expect("sink event within 5s")
            .expect("sink channel open")
    }

    /// Assert nothing further arrives. A short window, not a proof — paired
    /// with `next` it is what makes "exactly one terminal" checkable at all.
    async fn quiet(rx: &mut mpsc::UnboundedReceiver<Ev>) {
        if let Ok(Some(ev)) = tokio::time::timeout(Duration::from_millis(300), rx.recv()).await {
            panic!("expected no further sink calls, got {ev:?}");
        }
    }

    /// Echo server. Hands back the upgrade request's headers so a leg can
    /// assert what the handshake carried.
    async fn echo_server() -> (String, tokio::sync::oneshot::Receiver<Vec<(String, String)>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/v1/realtime", listener.local_addr().unwrap());
        let (htx, hrx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let cb = move |req: &Request, resp: Response| {
                let hs = req
                    .headers()
                    .iter()
                    .map(|(k, v)| (k.as_str().to_string(), v.to_str().unwrap_or("").to_string()))
                    .collect();
                let _ = htx.send(hs);
                Ok(resp)
            };
            let mut ws = tokio_tungstenite::accept_hdr_async(stream, cb).await.unwrap();
            while let Some(Ok(m)) = ws.next().await {
                match m {
                    Message::Text(_) | Message::Binary(_) => ws.send(m).await.unwrap(),
                    // Keep polling: tungstenite queues the close REPLY and
                    // only writes it on the next poll. Breaking here dropped
                    // the socket first and the client saw a reset — a test
                    // server fault, measured, not a client one.
                    Message::Close(_) => {}
                    _ => {}
                }
            }
        });
        (url, hrx)
    }

    #[tokio::test]
    async fn handshake_carries_passed_in_headers_verbatim() {
        let (url, hrx) = echo_server().await;
        let (sink, _rx) = recorder();
        let conn = RealtimeConnect {
            url,
            headers: vec![
                RealtimeHeader { name: "Authorization".into(), value: "Bearer ephemeral-test-0001".into() },
                RealtimeHeader { name: "OpenAI-Beta".into(), value: "realtime=v1".into() },
            ],
        };
        let _s = open(conn, sink).await.expect("connect");
        let hs = hrx.await.unwrap();
        let get = |n: &str| hs.iter().find(|(k, _)| k.eq_ignore_ascii_case(n)).map(|(_, v)| v.clone());
        assert_eq!(get("authorization").as_deref(), Some("Bearer ephemeral-test-0001"));
        assert_eq!(get("openai-beta").as_deref(), Some("realtime=v1"));
        // Vacuity control: a header we did NOT pass is absent, so the lookup
        // can say no.
        assert_eq!(get("x-not-sent"), None);
    }

    #[tokio::test]
    async fn text_and_binary_round_trip_then_one_close() {
        let (url, _h) = echo_server().await;
        let (sink, mut rx) = recorder();
        let s = open(RealtimeConnect { url, headers: vec![] }, sink).await.expect("connect");

        s.send_text("{\"type\":\"session.update\"}".into()).unwrap();
        s.send_binary(vec![0x00, 0x7f, 0x80, 0xff]).unwrap();
        assert_eq!(next(&mut rx).await, Ev::Text("{\"type\":\"session.update\"}".into()));
        assert_eq!(next(&mut rx).await, Ev::Binary(vec![0x00, 0x7f, 0x80, 0xff]));
        assert!(!s.is_closed());

        s.close();
        assert_eq!(next(&mut rx).await, Ev::Closed(Some(1000), String::new()));
        quiet(&mut rx).await;
        assert!(s.is_closed());
        assert!(matches!(s.send_text("late".into()), Err(RealtimeError::Closed)));
        assert!(matches!(s.send_binary(vec![1]), Err(RealtimeError::Closed)));
    }

    #[tokio::test]
    async fn server_close_reaches_sink_once_with_code_and_reason() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
            ws.send(Message::Text("hi".into())).await.unwrap();
            let f = CloseFrame { code: CloseCode::Away, reason: "session expired".into() };
            ws.send(Message::Close(Some(f))).await.unwrap();
            while ws.next().await.is_some() {}
        });
        let (sink, mut rx) = recorder();
        let s = open(RealtimeConnect { url, headers: vec![] }, sink).await.expect("connect");
        assert_eq!(next(&mut rx).await, Ev::Text("hi".into()));
        assert_eq!(next(&mut rx).await, Ev::Closed(Some(1001), "session expired".into()));
        quiet(&mut rx).await;
        assert!(s.is_closed());
        // The case `push`'s terminal check exists for: the PEER closed, so the
        // writer task is still alive and its queue would happily accept a
        // frame that can never be delivered. After a LOCAL close the queue
        // refuses on its own — measured: deleting the check survived the
        // local-close leg, and is caught only here.
        assert!(matches!(s.send_text("after peer close".into()), Err(RealtimeError::Closed)));
    }

    /// Queue bound. `#[tokio::test]` is a current-thread runtime and
    /// `send_*` is a synchronous `try_send`, so the writer task (spawned in
    /// `open`, never yielded to here) cannot drain a single frame between
    /// these calls. That makes the bound exact rather than "eventually":
    /// sends 1..=SEND_QUEUE_DEPTH are admitted, the next is `QueueFull`.
    /// Catches: depth changed, `Full` mapped to `Closed`, queue made unbounded.
    #[tokio::test]
    async fn queue_refuses_with_queue_full_one_past_depth() {
        let (url, _h) = echo_server().await;
        let (sink, _rx) = recorder();
        let s = open(RealtimeConnect { url, headers: vec![] }, sink).await.expect("connect");

        for i in 0..SEND_QUEUE_DEPTH {
            assert!(s.send_text(format!("f{i}")).is_ok(), "send {} refused below depth", i + 1);
        }
        let over = s.send_text("one too many".into());
        assert!(matches!(over, Err(RealtimeError::QueueFull)), "send {} got {over:?}", SEND_QUEUE_DEPTH + 1);
        // Binary shares the queue and the bound.
        assert!(matches!(s.send_binary(vec![0]), Err(RealtimeError::QueueFull)));
        // Vacuity control: a full queue is not a closed session.
        assert!(!s.is_closed());
    }

    /// `close()` jumps a full queue. Fill to the bound (writer not yet
    /// polled, see above), then close. The echo server reflects every frame
    /// it receives, so if close waited its turn behind the 256 queued frames
    /// the sink would see `Text` echoes first. What must arrive is the close
    /// terminal, first, within `next`'s 5s bound, and nothing after it.
    /// Catches: close routed through the frame queue. Removing `biased` is
    /// caught only probabilistically (fair select picks close first ~half the
    /// time), so this is not a guard on `biased` alone.
    #[tokio::test]
    async fn close_with_full_queue_reaches_terminal_before_any_queued_frame() {
        let (url, _h) = echo_server().await;
        let (sink, mut rx) = recorder();
        let s = open(RealtimeConnect { url, headers: vec![] }, sink).await.expect("connect");

        for i in 0..SEND_QUEUE_DEPTH {
            s.send_text(format!("queued {i}")).expect("below depth");
        }
        assert!(matches!(s.send_text("full".into()), Err(RealtimeError::QueueFull)));

        s.close();
        assert_eq!(next(&mut rx).await, Ev::Closed(Some(1000), String::new()));
        quiet(&mut rx).await;
        assert!(s.is_closed());
        assert!(matches!(s.send_text("late".into()), Err(RealtimeError::Closed)));
    }

    /// The latch, driven directly. The socket legs cannot force reader and
    /// writer to both observe one ending (it is an interleaving), so removing
    /// the latch SURVIVED every one of them — measured. This leg is where the
    /// "exactly one terminal" contract is actually guarded.
    #[tokio::test]
    async fn terminal_latch_admits_exactly_one_call() {
        for order in 0..3 {
            let (sink, mut rx) = recorder();
            let t = Terminal { sink, fired: AtomicBool::new(false) };
            assert!(!t.is_fired());
            match order {
                0 => { t.closed(Some(1000), "a".into()); t.closed(None, "b".into()); }
                1 => { t.closed(Some(1000), "a".into()); t.error("b".into()); }
                _ => { t.error("a".into()); t.closed(Some(1000), "b".into()); }
            }
            let first = next(&mut rx).await;
            let want_first = if order == 2 { Ev::Error("a".into()) } else { Ev::Closed(Some(1000), "a".into()) };
            assert_eq!(first, want_first, "order {order}");
            quiet(&mut rx).await;
            assert!(t.is_fired());
        }
    }

    #[tokio::test]
    async fn dropped_tcp_without_close_frame_is_one_terminal() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let ws = tokio_tungstenite::accept_async(stream).await.unwrap();
            drop(ws); // no close handshake
        });
        let (sink, mut rx) = recorder();
        let s = open(RealtimeConnect { url, headers: vec![] }, sink).await.expect("connect");
        let ev = next(&mut rx).await;
        // An abrupt drop is either a frameless close or a protocol error,
        // depending on what the kernel reports first. Both are terminal; what
        // is asserted is that exactly one arrives.
        assert!(matches!(ev, Ev::Closed(None, _) | Ev::Error(_)), "got {ev:?}");
        quiet(&mut rx).await;
        assert!(s.is_closed());
    }

    #[tokio::test]
    async fn refused_connect_is_a_typed_error() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        drop(listener);
        let (sink, mut rx) = recorder();
        let r = open(RealtimeConnect { url, headers: vec![] }, sink).await;
        assert!(matches!(r, Err(RealtimeError::Connect(_))), "got {:?}", r.err());
        quiet(&mut rx).await; // no session, so no sink traffic
    }

    #[test]
    fn bad_header_is_refused_by_name_without_echoing_the_value() {
        let secret = "sk-live-must-not-appear";
        let conn = RealtimeConnect {
            url: "ws://127.0.0.1:1/".into(),
            headers: vec![RealtimeHeader { name: "Authorization".into(), value: format!("Bearer {secret}\n") }],
        };
        let err = build_request(&conn).unwrap_err();
        assert!(matches!(err, RealtimeError::BadHeader(ref n) if n == "Authorization"));
        assert!(!err.to_string().contains(secret), "error leaked the credential: {err}");

        // Control: the same header with a clean value is accepted, so the
        // refusal above is about the newline and not about the header.
        let ok = RealtimeConnect {
            url: conn.url.clone(),
            headers: vec![RealtimeHeader { name: "Authorization".into(), value: format!("Bearer {secret}") }],
        };
        assert!(build_request(&ok).is_ok());
    }

    #[test]
    fn non_ws_url_is_refused() {
        let conn = RealtimeConnect { url: "https://example.invalid/".into(), headers: vec![] };
        assert!(matches!(build_request(&conn), Err(RealtimeError::BadUrl(_))));
    }
}
