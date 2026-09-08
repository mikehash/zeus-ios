//! # zeus-core-bridge
//!
//! UniFFI bridge exposing the Zeus core to the iOS app. **The gateway runs on
//! the phone**: this crate is the substrate under `EmbeddedTransport`, not a
//! client for a remote one.
//!
//! ## What is pinned, and why the set is exactly five
//!
//! **The pin is not repeated in this prose.** It lived here as the literal
//! `2a2168cd` across two commits that moved it (`b30b6dd`, `a9f4d36`) and was
//! wrong in a tracked file both times — the same defect the manifest's
//! `dep-pin`/`crate-tree` keys exist to make visible, one register down where
//! no guard can see it. The pin is `rev = ` in this crate's `Cargo.toml`, and
//! `scripts/check_crate_tree.sh` is what asserts the built artifact agrees
//! with it. A sha typed in a doc comment is a claim with no reader.
//!
//! The five crates are `zeus-core`, `zeus-llm`, `zeus-session`, `zeus-memory`
//! and `zeus-agent`. `zeus-agent` joined once its `automation` feature gate
//! landed: it is taken with `default-features = false`, which is what keeps
//! the 14 objc2 framework crates behind `zeus-talos` out of the iOS graph.
//! Both `aarch64-apple-ios` and `-sim` are MEASURED green under
//! `rustc 1.95.0` (the crate-root `rust-toolchain.toml`) — that aperture is
//! stated because a green check is a fact about a toolchain, not about the
//! code. `zeus-mnemosyne` is absent: `rusqlite`/`bundled` is a C sqlite build
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
use zeus_llm::{LlmClient, OllamaClient, normalize_ollama_url};
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
    /// A typed refusal, distinct from an empty result. `list_models` returns
    /// this for every provider that is not `ollama` rather than `Ok(vec![])`,
    /// because an empty vector and "this crate does not answer for you" render
    /// identically in a picker and only one of them is the caller's fault.
    #[error("listing models is not supported for provider {0} in v1")]
    Unsupported(String),
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
    ///
    /// ## `base_url` and why it is a process env write, not a parameter
    ///
    /// `LlmClient` resolves its base URL inside `with_api_key` → `new`, and for
    /// Ollama that arm reads `env::var("OLLAMA_HOST")` (zeus-llm:1018) with
    /// `http://localhost:11434` as the fallback. There is no constructor that
    /// takes a URL, so the ONLY seam an out-of-crate caller has is the process
    /// environment, and it must be written BEFORE construction — after is a
    /// no-op, because the URL is already baked into the client. On iOS there is
    /// no shell to export it from, so the bridge is the only place it can
    /// happen. `None` leaves the environment untouched: a caller who passes
    /// nothing gets the core's own default rather than an empty string, which
    /// `normalize_ollama_url` would silently turn back into localhost anyway.
    ///
    /// Non-Ollama providers ignore `base_url` entirely — their arms are
    /// literals in the same match. Passing one is not an error and not honoured;
    /// stated here rather than discovered, since a silently-dropped URL is the
    /// worse of the two failures.
    pub fn set_provider(
        self: Arc<Self>,
        id: String,
        model: String,
        key: String,
        base_url: Option<String>,
    ) -> Result<(), BridgeError> {
        let provider = resolve_provider(&id)?;
        apply_base_url(provider, base_url.as_deref());
        let client = LlmClient::with_api_key(provider, model, key)?;
        self.rt
            .block_on(async { *self.client.lock().await = Some(Arc::new(client)) });
        Ok(())
    }

    /// The models `id` can serve, asked of the provider rather than hardcoded.
    ///
    /// v1 answers for `ollama` only, via `OllamaClient::list_models`
    /// (zeus-llm/ollama.rs:171), because it is the one provider whose catalogue
    /// is a property of the operator's own machine — every other provider's
    /// list is a published constant that belongs in a picker, not in a network
    /// call. The rest return `Unsupported` with the prefix named, so a caller
    /// gets a typed refusal instead of an empty `Vec` that reads exactly like
    /// "this provider has no models".
    ///
    /// `base_url` is honoured directly here (the Ollama client takes one at
    /// construction, unlike `LlmClient`), so this call does NOT touch the
    /// process environment.
    pub fn list_models(
        self: Arc<Self>,
        id: String,
        key: String,
        base_url: Option<String>,
    ) -> Result<Vec<String>, BridgeError> {
        let provider = resolve_provider(&id)?;
        if provider != Provider::Ollama {
            return Err(BridgeError::Unsupported(id));
        }
        let url = normalize_ollama_url(base_url.as_deref().unwrap_or(OLLAMA_DEFAULT_URL));
        let client = if key.is_empty() {
            OllamaClient::new(url)
        } else {
            OllamaClient::with_auth(url, key)
        };
        let models = self
            .rt
            .block_on(async move { client.list_models().await })?;
        Ok(models.into_iter().map(|m| m.name).collect())
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

    /// Whether a provider has been selected on THIS core.
    ///
    /// ## The subject, stated because a near-neighbour is what shipped before
    ///
    /// This reads the one `Option` that `send` reads (`self.client`), so it
    /// answers exactly the question `send` will answer: is there a client to
    /// send with. It is NOT "did the operator pick a provider" — that fact
    /// lives on disk in the commission, and Swift derived readiness from it
    /// while this `Option` was `None` for the life of the process. A string
    /// on disk and an armed core are two different subjects; the UI showed
    /// READY on the first and sent on the second.
    ///
    /// ## What it does NOT promise
    ///
    /// `true` means a `LlmClient` was constructed — the key was non-empty and
    /// the prefix resolved. It says nothing about whether the provider is
    /// REACHABLE or the key is VALID; both of those are discovered on send and
    /// arrive as the provider's own error text. Unarmed and unreachable are
    /// two different failures and this call only sees the first.
    pub fn has_provider(self: Arc<Self>) -> bool {
        self.rt
            .block_on(async { self.client.lock().await.is_some() })
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

/// The core's own Ollama fallback, spelled once here so the two readers
/// (`apply_base_url` and `list_models`) cannot drift apart. It is a COPY of
/// zeus-llm:1018's literal, not a shared constant — zeus-llm does not export
/// one — so a change there is invisible here; the guard is
/// `apply_base_url_none_leaves_the_core_default`, which asserts through the
/// core rather than against this string.
const OLLAMA_DEFAULT_URL: &str = "http://localhost:11434";

/// Write `OLLAMA_HOST` for the Ollama arm so the client built next reads it.
///
/// Extracted from `set_provider` for the same reason `resolve_provider` was: a
/// method taking `Arc<Self>` needs a live workspace to reach, so the branch
/// would be unguardable in-crate. As a free function both arms are directly
/// asserted below.
///
/// `env::set_var` is process-global and this crate is a single-core-per-process
/// library on iOS, so the write is not racing a second core. Stated because the
/// same call in a multi-core host WOULD be a data race — the safety is a
/// property of the deployment, not of this function.
fn apply_base_url(provider: Provider, base_url: Option<&str>) {
    if provider != Provider::Ollama {
        return;
    }
    if let Some(raw) = base_url {
        let normalized = normalize_ollama_url(raw);
        // SAFETY: single-threaded configuration point on iOS; see the doc above.
        unsafe { std::env::set_var("OLLAMA_HOST", normalized) };
    }
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

    /// `OLLAMA_HOST` is process-global and cargo runs tests on threads, so the
    /// three env-touching legs below must not interleave. Poison is recovered
    /// rather than propagated (`into_inner`): a panic in one leg should fail
    /// THAT leg, not convert the other two into a second, misleading failure.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// Put `OLLAMA_HOST` back exactly as found — including ABSENT, which
    /// `set_var("")` would not restore: an empty value is a present variable,
    /// and `normalize_ollama_url("")` turns it back into localhost, so the
    /// difference is invisible at the client and visible only here.
    fn restore_ollama_host(previous: &Option<String>) {
        // SAFETY: called only under ENV_LOCK; see the doc on apply_base_url.
        unsafe {
            match previous {
                Some(v) => std::env::set_var("OLLAMA_HOST", v),
                None => std::env::remove_var("OLLAMA_HOST"),
            }
        }
    }

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
    /// `has_provider` must read the SAME cell `send` reads, and it must
    /// discriminate — a getter hardcoded to `true` passes any armed-only test,
    /// and one hardcoded to `false` passes any unarmed-only test. So both arms
    /// are asserted on ONE core, with an explicit not-equal so a collapsed
    /// implementation cannot green both.
    ///
    /// No network: `set_provider` constructs the client and does not contact
    /// the provider. This says nothing about reachability — see the export's
    /// doc comment.
    #[test]
    fn has_provider_reports_the_cell_send_reads() {
        let dir = std::env::temp_dir().join(format!("zcb-armed-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let core = ZeusCore::init(dir.to_string_lossy().to_string()).unwrap();

        let before = core.clone().has_provider();
        assert!(!before, "a freshly built core has selected no provider");

        core.clone()
            .set_provider(
                "ollama".into(),
                "qwen3:8b".into(),
                "unused-by-ollama".into(),
                None,
            )
            .expect("the ollama prefix resolves and a non-empty key builds a client");

        let after = core.clone().has_provider();
        assert!(after, "after set_provider the core must report armed");
        assert_ne!(
            before, after,
            "has_provider must DISCRIMINATE — a constant passes one arm and this \
             pair is the only thing that refuses it"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The URL seam, asserted where it is OBSERVABLE.
    ///
    /// `set_provider` swallows the client into a `Mutex` the tests cannot reach
    /// without a live workspace, so the subject here is the pair
    /// (`apply_base_url`, `LlmClient::with_api_key`) run in the same order the
    /// export runs them, read back through `LlmClient::base_url()`
    /// (zeus-llm:991). That is the exact value the request will be sent to —
    /// asserting on `env::var("OLLAMA_HOST")` instead would assert that I wrote
    /// the variable, not that the core read it, and those came apart once
    /// already (a write placed AFTER construction is a silent no-op).
    ///
    /// Serialised with the two legs below via `ENV_LOCK`: `OLLAMA_HOST` is
    /// process-global and cargo runs tests on threads, so an unlocked pair
    /// would flake in one direction only — which is worse than failing.
    #[test]
    fn base_url_reaches_the_client_the_core_will_send_with() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let previous = std::env::var("OLLAMA_HOST").ok();

        apply_base_url(Provider::Ollama, Some("http://10.0.0.7:11434/v1/"));
        let client =
            LlmClient::with_api_key(Provider::Ollama, "qwen3:8b".into(), "unused".into()).unwrap();
        assert_eq!(
            client.base_url(),
            "http://10.0.0.7:11434",
            "the client must resolve the URL handed to set_provider, normalized"
        );

        // Vacuity: the default must DIFFER from the value above, or an
        // apply_base_url that did nothing at all would pass the assertion.
        restore_ollama_host(&previous);
        let defaulted =
            LlmClient::with_api_key(Provider::Ollama, "qwen3:8b".into(), "unused".into()).unwrap();
        assert_ne!(
            client.base_url(),
            defaulted.base_url(),
            "a no-op apply_base_url would green the first assertion — this pair refuses it"
        );
    }

    /// The no-op arms, both of them, because "ignores base_url" is a claim in
    /// the export's doc comment and an unasserted doc comment is prose.
    #[test]
    fn base_url_is_applied_only_for_ollama_and_only_when_given() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let previous = std::env::var("OLLAMA_HOST").ok();
        restore_ollama_host(&None);

        // Arm 1: a non-Ollama provider must not write the variable.
        apply_base_url(Provider::Anthropic, Some("http://should-not-be-written:1"));
        assert!(
            std::env::var("OLLAMA_HOST").is_err(),
            "a non-ollama provider must leave OLLAMA_HOST untouched"
        );

        // Arm 2: None must not write it either — the caller gets the core's
        // own default rather than an empty string.
        apply_base_url(Provider::Ollama, None);
        assert!(
            std::env::var("OLLAMA_HOST").is_err(),
            "None must leave the environment untouched, not write an empty value"
        );

        // POS control in the same invocation: the writer is alive. Without
        // this, a permanently-broken apply_base_url passes both arms above.
        apply_base_url(Provider::Ollama, Some("http://10.0.0.9:11434"));
        assert_eq!(
            std::env::var("OLLAMA_HOST").ok().as_deref(),
            Some("http://10.0.0.9:11434"),
            "control: the ollama arm with a URL DOES write"
        );

        restore_ollama_host(&previous);
    }

    /// `list_models` refuses non-ollama prefixes with a TYPED error naming the
    /// prefix, and it must not be an empty `Vec` — the two render identically
    /// in a picker. No network: the refusal happens before any request, which
    /// is why this leg is safe to run in CI while the ollama arm is not.
    #[test]
    fn list_models_refuses_unsupported_providers_by_type() {
        let dir = std::env::temp_dir().join(format!("zcb-list-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let core = ZeusCore::init(dir.to_string_lossy().to_string()).unwrap();

        match core
            .clone()
            .list_models("anthropic".into(), "k".into(), None)
        {
            Err(BridgeError::Unsupported(p)) => assert_eq!(
                p, "anthropic",
                "the refusal must name the prefix the caller passed"
            ),
            other => panic!("expected a typed Unsupported refusal, got {other:?}"),
        }

        // An unknown prefix is a DIFFERENT failure and must not be absorbed
        // into Unsupported — resolve_provider refuses it first.
        match core.clone().list_models("nosuchprovider".into(), "k".into(), None) {
            Err(BridgeError::Core(msg)) => assert!(
                msg.contains("nosuchprovider"),
                "an unknown prefix is a Core error naming it, not Unsupported"
            ),
            other => panic!("expected Core for an unknown prefix, got {other:?}"),
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

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
