//! # zeus-core-bridge
//!
//! UniFFI bridge exposing the Zeus core to the iOS app. **The gateway runs on
//! the phone**: this crate is the substrate under `EmbeddedTransport`, not a
//! client for a remote one.
//!
//! ## What is pinned, and why the set is exactly four
//!
//! Every Zeus dependency is pinned to `mikehash/Zeus@2a2168cd`. The four crates
//! (`zeus-core`, `zeus-llm`, `zeus-session`, `zeus-memory`) are the set MEASURED
//! green for `aarch64-apple-ios` — 0 errors in 2m07s on Xcode 26.5 / SDK 26.5 /
//! rustc 1.97.1. That aperture is stated because a green check is a fact about a
//! toolchain, not about the code.
//!
//! `zeus-agent` is absent: its iOS graph hard-links 14 objc2 framework crates
//! through `zeus-talos`. It joins once the `automation` feature gate lands on
//! main. `zeus-mnemosyne` is absent: `rusqlite`/`bundled` is a C sqlite build
//! never cross-compiled against the iOS SDK here.
//!
//! ## The one piece of real engineering
//!
//! `LlmClient::stream` returns `(mpsc::Receiver<String>, JoinHandle<LlmResponse>)`.
//! A UniFFI callback cannot carry a `Receiver` across the FFI boundary, so the
//! bridge owns a tokio runtime, pumps the channel into a Swift callback object,
//! and joins for the final response. The other five exports are wrappers.

use std::sync::Arc;

use tokio::runtime::Runtime;
use tokio::sync::Mutex;

use zeus_core::Provider;
use zeus_llm::LlmClient;
use zeus_memory::{FileEntry, FileIndex, Workspace};
use zeus_session::Session;

uniffi::setup_scaffolding!();

// ============================================================================
// Errors
// ============================================================================

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BridgeError {
    #[error("no provider configured — call set_provider first")]
    NoProvider,
    #[error("{0}")]
    Core(String),
}

// The core's fallible surface returns `zeus_core::Error`, NOT `anyhow::Error` —
// measured, not assumed: the first `cargo check` produced five E0277s, all of
// this one shape. Keeping both impls because `anyhow` is still the error type
// crossing some helper boundaries here; dropping it would trade five errors for
// a different five.
impl From<zeus_core::Error> for BridgeError {
    fn from(e: zeus_core::Error) -> Self {
        BridgeError::Core(e.to_string())
    }
}

impl From<anyhow::Error> for BridgeError {
    fn from(e: anyhow::Error) -> Self {
        BridgeError::Core(e.to_string())
    }
}

// ============================================================================
// Records
// ============================================================================

/// A session, flattened for Swift. `Session::list` yields
/// `(String, DateTime<Utc>)`; `DateTime` has no UniFFI representation, so the
/// timestamp crosses as RFC3339 text and Swift parses it. Deliberate: an i64
/// epoch would silently lose the timezone the core carries.
#[derive(uniffi::Record)]
pub struct SessionInfo {
    pub id: String,
    pub updated_at_rfc3339: String,
}

/// One hit from the workspace file index.
#[derive(uniffi::Record)]
pub struct SearchHit {
    pub path: String,
    pub name: String,
    pub score: f64,
    pub context: Option<String>,
    pub line_number: Option<u32>,
}

// ============================================================================
// Streaming callback
// ============================================================================

/// Swift implements this; the bridge calls it from the runtime thread as tokens
/// arrive. `on_token` may be called many times, then exactly one of
/// `on_complete` / `on_error`.
#[uniffi::export(callback_interface)]
pub trait TokenSink: Send + Sync + 'static {
    fn on_token(&self, token: String);
    fn on_complete(&self, full_text: String);
    fn on_error(&self, message: String);
}

// ============================================================================
// The bridge object
// ============================================================================

/// The bridge IS the runtime owner. `init` constructs it; it lives for the
/// process. Every async core call is driven by this runtime — there is no
/// ambient executor on the phone.
#[derive(uniffi::Object)]
pub struct ZeusCore {
    rt: Runtime,
    workspace: Workspace,
    sessions_dir: std::path::PathBuf,
    /// Populated at construction by `scan_workspace`. See `search` for the
    /// staleness contract — this is a snapshot, not a live view.
    index: FileIndex,
    client: Mutex<Option<Arc<LlmClient>>>,
}

#[uniffi::export]
impl ZeusCore {
    /// Build the core rooted at `workspace_dir`.
    ///
    /// Constructor, not a free function: the runtime must outlive every call,
    /// and a `#[uniffi::constructor]` is the only shape where Swift's ARC keeps
    /// it alive for us.
    #[uniffi::constructor]
    pub fn init(workspace_dir: String) -> Result<Arc<Self>, BridgeError> {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| BridgeError::Core(e.to_string()))?;

        let root = std::path::PathBuf::from(&workspace_dir);
        let workspace = Workspace::new(&root);
        rt.block_on(workspace.init())?;

        // MEASURED, and the reason this scan exists: `FileIndex` has ZERO
        // production consumers in the pin — every `FileEntry::new` call site
        // sits above `#[cfg(test)]` at indexer.rs:414 (0 prod hits; POS control
        // `LlmClient` outside zeus-llm = 209). The index type is complete and
        // tested but nothing ever fills it, so calling `search` on a fresh
        // index returns `[]` forever and looks exactly like "no matches". The
        // bridge fills it here or `search` is a lie at the export.
        let index = scan_workspace(&root);

        let sessions_dir = root.join("sessions");

        Ok(Arc::new(Self {
            rt,
            workspace,
            sessions_dir,
            index,
            client: Mutex::new(None),
        }))
    }

    /// Select the model route. `id` is a provider prefix (`anthropic`,
    /// `openai`, `ollama`, `gemini`, `groq`, …).
    ///
    /// The prefix→enum map is `Provider::from_prefix` (zeus-core:8922) and NOT a
    /// second table here: it is the single source of truth for `{provider}/{model}`
    /// resolution, carries the aliases, and returns `None` on unrecognized input
    /// so the caller must decide the fallback (#559 — no silent mis-route to
    /// Anthropic's env key). A local table would be a second truth that drifts.
    pub fn set_provider(
        self: Arc<Self>,
        id: String,
        model: String,
        key: String,
    ) -> Result<(), BridgeError> {
        let provider = resolve_provider(&id)?;
        let client = LlmClient::with_api_key(provider, model, key)?;
        self.rt
            .block_on(async { *self.client.lock().await = Some(Arc::new(client)) });
        Ok(())
    }

    /// Send `text` on `session_id`, streaming tokens into `sink`.
    ///
    /// Blocks the calling thread for the duration — Swift calls it off the main
    /// actor. Chosen over a fire-and-forget spawn because a detached task whose
    /// handle nobody holds cannot be cancelled and cannot report a panic; the
    /// caller owning the thread is the honest shape for v1.
    pub fn send(
        self: Arc<Self>,
        session_id: String,
        text: String,
        sink: Box<dyn TokenSink>,
    ) -> Result<(), BridgeError> {
        let client = self
            .rt
            .block_on(async { self.client.lock().await.clone() })
            .ok_or(BridgeError::NoProvider)?;

        let _ = session_id; // v1: history is not yet threaded — see below.

        self.rt.block_on(async move {
            let messages = vec![zeus_core::Message::user(text)];
            // `stream`, not `stream_with_history`: session replay is a separate
            // cut. Named here rather than left implicit — a reader would
            // otherwise assume `session_id` selects history, and it does not.
            let (mut rx, handle) = match client.stream(&messages, &[], None).await {
                Ok(v) => v,
                Err(e) => {
                    sink.on_error(e.to_string());
                    return Ok(());
                }
            };

            let full = pump(&mut rx, sink.as_ref()).await;

            match handle.await {
                Ok(resp) => {
                    // Prefer the joined response's text when it is non-empty:
                    // the channel carries deltas, the response carries the
                    // authoritative body.
                    let text = if resp.content.is_empty() {
                        full
                    } else {
                        resp.content.clone()
                    };
                    sink.on_complete(text);
                }
                Err(e) => sink.on_error(format!("stream task failed: {e}")),
            }
            Ok(())
        })
    }

    /// List known sessions, newest first.
    pub fn sessions(self: Arc<Self>) -> Result<Vec<SessionInfo>, BridgeError> {
        let dir = self.sessions_dir.clone();
        let mut out = self.rt.block_on(async move {
            Session::list(&dir)
                .await
                .map(|v| {
                    v.into_iter()
                        .map(|(id, ts)| SessionInfo {
                            id,
                            updated_at_rfc3339: ts.to_rfc3339(),
                        })
                        .collect::<Vec<_>>()
                })
                .map_err(BridgeError::from)
        })?;
        out.sort_by(|a, b| b.updated_at_rfc3339.cmp(&a.updated_at_rfc3339));
        Ok(out)
    }

    /// Append a fact to workspace memory.
    pub fn remember(self: Arc<Self>, fact: String) -> Result<(), BridgeError> {
        self.rt
            .block_on(async { self.workspace.remember(&fact).await })?;
        Ok(())
    }

    /// Search the workspace file index.
    ///
    /// **Contract, stated because it is narrower than the name:** this reads an
    /// index of the workspace files scanned at `init`. It is a SNAPSHOT, not a
    /// live view — a file written after `init` is invisible until the process
    /// restarts. Re-scan policy is deferred to v1.1; when Mnemosyne is measured
    /// green under the iOS SDK it becomes a swap behind this same export and
    /// nothing in Swift changes.
    pub fn search(self: Arc<Self>, query: String) -> Vec<SearchHit> {
        self.index
            .search(&query)
            .into_iter()
            .map(|r| SearchHit {
                path: r.entry.path,
                name: r.entry.name,
                score: r.score,
                context: r.context,
                line_number: r.line_number.map(|n| n as u32),
            })
            .collect()
    }

    /// Number of files indexed at `init`.
    ///
    /// Exported for one reason: it is the only way a caller can tell "the query
    /// matched nothing" from "the index is empty", which are the two states the
    /// pin's unpopulated `FileIndex` makes indistinguishable. A vacuity probe,
    /// not a statistic.
    pub fn index_size(self: Arc<Self>) -> u32 {
        self.index.len() as u32
    }
}

// ============================================================================
// Provider resolution
// ============================================================================

/// Resolve a provider prefix, refusing the unknown.
///
/// Extracted from `set_provider` after a mutation survived: replacing the
/// `ok_or_else` with `.unwrap_or(Provider::Anthropic)` — literally the #559
/// silent-mis-route defect — left all four tests green, because the test named
/// `provider_prefix_is_the_core_map` asserts what `Provider::from_prefix`
/// RETURNS, not what this crate DOES with it. Inside an `#[uniffi::export]`
/// method taking `Arc<Self>`, the call site was unreachable without a live
/// workspace. As a free function it is directly guarded below.
fn resolve_provider(id: &str) -> Result<Provider, BridgeError> {
    Provider::from_prefix(id)
        .ok_or_else(|| BridgeError::Core(format!("unrecognized provider prefix: {id}")))
}

// ============================================================================
// The receiver→callback pump
// ============================================================================

/// Drain `rx` into `sink`, returning the accumulated text.
///
/// Extracted from `send` for one reason: this is the only piece of the bridge
/// that is neither a wrapper nor provided by the core, and inside `send` it is
/// unreachable from a test — reaching it would require a live provider, a
/// network, and a key. As a free function over any `Receiver<String>` it is
/// exercised by a test that feeds a channel directly, which is the same code
/// path the real stream takes.
async fn pump(rx: &mut tokio::sync::mpsc::Receiver<String>, sink: &dyn TokenSink) -> String {
    let mut full = String::new();
    while let Some(tok) = rx.recv().await {
        full.push_str(&tok);
        sink.on_token(tok);
    }
    full
}

// ============================================================================
// Workspace scan
// ============================================================================

/// Walk `root` and build the file index.
///
/// Hand-rolled rather than `walkdir` so `zeus-memory`'s dependency table stays
/// exactly as measured green (zeus-core, tokio, serde, thiserror, anyhow,
/// chrono, dirs, tracing — no additions). Depth-bounded and dot-skipping: an
/// unbounded walk of a workspace containing `.git` is a startup cost the phone
/// pays on every launch.
fn scan_workspace(root: &std::path::Path) -> FileIndex {
    const MAX_DEPTH: usize = 6;
    let mut index = FileIndex::new();
    let mut stack = vec![(root.to_path_buf(), 0usize)];

    while let Some((dir, depth)) = stack.pop() {
        if depth > MAX_DEPTH {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            if name.starts_with('.') {
                continue;
            }
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                stack.push((path, depth + 1));
            } else if meta.is_file() {
                let rel = path
                    .strip_prefix(root)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .to_string();
                index.add(FileEntry::new(&rel, name, meta.len()));
            }
        }
    }

    index
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The scan is the whole reason `search` can return anything. This test
    /// asserts BOTH directions — a hit for a file that exists and no hit for a
    /// term that does not — because a scan that indexed everything under one
    /// key would pass a hit-only test.
    #[test]
    fn scan_populates_index_and_search_discriminates() {
        let dir = std::env::temp_dir().join(format!("zcb-scan-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("notes")).unwrap();
        std::fs::write(dir.join("notes/deploy-runbook.md"), "how to deploy").unwrap();
        std::fs::write(dir.join("README.md"), "readme").unwrap();

        let index = scan_workspace(&dir);
        assert_eq!(index.len(), 2, "scan must find both files");

        let hits = index.search("runbook");
        assert_eq!(hits.len(), 1, "term present in one filename");
        assert!(hits[0].entry.path.ends_with("deploy-runbook.md"));

        // Vacuity leg: without this, an index that scored every file for every
        // query would pass the assertion above.
        assert!(
            index.search("kubernetes").is_empty(),
            "absent term must not match"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Guards the defect the scan exists to fix: an empty index is
    /// indistinguishable from a no-match, so `index_size` must separate them.
    #[test]
    fn empty_workspace_yields_empty_index() {
        let dir = std::env::temp_dir().join(format!("zcb-empty-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let index = scan_workspace(&dir);
        assert_eq!(index.len(), 0);
        assert!(index.search("anything").is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Recording sink: proves ORDER and CONTENT, not just arrival.
    #[derive(Default)]
    struct Recorder {
        tokens: std::sync::Mutex<Vec<String>>,
    }
    impl TokenSink for Recorder {
        fn on_token(&self, token: String) {
            self.tokens.lock().unwrap().push(token);
        }
        fn on_complete(&self, _full_text: String) {}
        fn on_error(&self, _message: String) {}
    }

    /// The streamed-token leg. Feeds a real `mpsc::Receiver` — the exact type
    /// `LlmClient::stream` returns — through the exact function `send` calls.
    /// No provider, no network, no key: the FFI-side pump is the subject, and
    /// mocking the provider instead would test reqwest.
    #[test]
    fn pump_forwards_each_token_in_order_and_accumulates() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(8);
            tokio::spawn(async move {
                for t in ["Zeus ", "core ", "is ", "live"] {
                    tx.send(t.to_string()).await.unwrap();
                }
                // Drop closes the channel; the pump must terminate on close,
                // not hang. A pump that never returned would fail this test by
                // timeout rather than by assertion — which is why the sender is
                // dropped explicitly here instead of relying on scope exit.
                drop(tx);
            });

            let sink = Recorder::default();
            let full = pump(&mut rx, &sink).await;

            assert_eq!(full, "Zeus core is live", "accumulated text");
            let seen = sink.tokens.lock().unwrap().clone();
            assert_eq!(
                seen,
                vec!["Zeus ", "core ", "is ", "live"],
                "every token forwarded, in order"
            );
            // Vacuity: a pump that accumulated but never called the sink would
            // pass the first assertion alone.
            assert_ne!(seen.len(), 0, "sink was actually invoked");
        });
    }

    /// `set_provider` must route through `Provider::from_prefix` — including
    /// its aliases — and must refuse unknown prefixes rather than defaulting.
    #[test]
    fn provider_prefix_is_the_core_map() {
        assert_eq!(Provider::from_prefix("anthropic"), Some(Provider::Anthropic));
        assert_eq!(Provider::from_prefix("gemini"), Some(Provider::Google));
        assert_eq!(Provider::from_prefix("nosuchprovider"), None);
    }

    /// The guard the test above does NOT provide. It asserts what the CORE's
    /// function returns; this asserts what THIS CRATE does with an unknown
    /// prefix — the difference a surviving mutation exposed.
    #[test]
    fn unknown_provider_prefix_is_refused_not_defaulted() {
        // Positive control in the same test: the resolver works at all.
        assert_eq!(resolve_provider("gemini").unwrap(), Provider::Google);

        let err = resolve_provider("nosuchprovider")
            .expect_err("unknown prefix must be an error, never a default");
        assert!(
            matches!(&err, BridgeError::Core(m) if m.contains("nosuchprovider")),
            "the error must name the offending prefix, got: {err}"
        );
    }
}
