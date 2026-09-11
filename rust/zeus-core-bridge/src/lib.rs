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

use zeus_core::{CredentialShape as CoreCredentialShape, Provider};
use zeus_llm::{LlmClient, OllamaClient, normalize_ollama_url};
use zeus_memory::{FileEntry, FileIndex, Workspace};
use zeus_session::Session;
use zeus_agent::{Agent, AgentEvent};
use zeus_agent::tools::set_workspace_root;

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
    /// The retirement of `OLLAMA_DEFAULT_URL`. A phone has no `localhost:11434`
    /// — the loopback on iOS is the PHONE, and nothing serves Ollama there — so
    /// defaulting to it turned "you did not give me a URL" into a connection
    /// error against the device itself, four seconds later, with a message
    /// naming the wrong subject. The absent input is now refused at the door.
    #[error("ollama needs a base URL — there is no default on a phone")]
    NoBaseUrl,
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
}

// ============================================================================
// Streaming callback
// ============================================================================

/// Swift implements this; the bridge calls it from the runtime thread as tokens
/// arrive. `on_token` may be called many times, then exactly one of
/// `on_complete` / `on_error`.
/// One message of a persisted session, flattened for Swift.
///
/// `tool_name` is `Some` only for `role == "tool"` rows whose name could be
/// RECOVERED — it is not a field the persisted row carries. See `messages()`
/// for why this is a join and not a read.
#[derive(uniffi::Record)]
pub struct TurnMessage {
    pub role: String,
    pub content: String,
    pub timestamp_rfc3339: String,
    pub tool_name: Option<String>,
}

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
    /// The canonical workspace root, RETAINED rather than read back.
    ///
    /// `zeus_agent::tools::workspace_root()` is private on main by design — it
    /// is the guard's own read, and a public getter would let this crate
    /// *believe* a process global instead of *owning* the value it set. Loop and
    /// index share one root because ONE VALUE FEEDS BOTH, not because a getter
    /// agreed. Gate (b) found the privacy by probing the symbol from here; the
    /// finding is the reason this field exists.
    root: std::path::PathBuf,
    /// The live index, behind a lock because `remember` now re-indexes.
    ///
    /// Was a plain `FileIndex`: `search` read a snapshot built at `init` and a
    /// fact written seconds earlier was invisible until relaunch. D3 named the
    /// two halves — content tokens AND a re-index — and this is the second.
    index: std::sync::RwLock<FileIndex>,
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
        // The loop persists a turn through `Session::resume_or_create`, which
        // does NOT create its parent. `Workspace::init` above makes the
        // workspace but not this; without it every persisted turn fails on a
        // missing directory and `sessions()` stays empty for a reason that
        // reads exactly like "no sessions yet".
        std::fs::create_dir_all(&sessions_dir)
            .map_err(|e| BridgeError::Core(format!("sessions dir: {e}")))?;

        // Canonicalise ONCE, here, and keep the result. On iOS the container
        // path is a symlink chain (`/var` → `/private/var`), so a root stored
        // uncanonicalised never `starts_with` any canonical tool path and the
        // guard would refuse the app's OWN workspace while looking perfect from
        // the refusal side. `set_workspace_root` canonicalises too; this crate
        // does it as well so the value it RETAINS is the same one it set.
        let canonical_root = root.canonicalize().unwrap_or_else(|_| root.clone());

        // D2's production caller. The allow-list buys nothing about paths — it
        // decides which tools exist, not where they may reach — so the
        // confinement is this call, landed on main as `5ec2c557`. The OS
        // sandbox is the SECOND wall: the simulator does not enforce it, and
        // every frame we shoot is a simulator frame.
        set_workspace_root(Some(canonical_root.clone()));

        Ok(Arc::new(Self {
            rt,
            workspace,
            sessions_dir,
            root: canonical_root,
            index: std::sync::RwLock::new(index),
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
    /// v1 answered for `ollama` ONLY, and the doc here said every other
    /// provider's list "is a published constant that belongs in a picker".
    /// That was true of the substrate it was written against and is no longer:
    /// `2d5775ee` moved the TUI's live fetcher into zeus-llm as
    /// `model_catalog::fetch_models`, and the pin ALREADY LINKS IT — 13 live
    /// arms (anthropic, openai, google, groq, openrouter, glm, mimo, kimi,
    /// qwen, xai, sakana, glm-coding, ollama), `reqwest` already that crate's
    /// dependency. So the refusal was a policy, not a limit, and the operator
    /// asked for the policy to change.
    ///
    /// THREE OUTCOMES, KEPT DISTINCT — the whole point of the surface:
    ///   - unknown prefix          → `Core`, naming the id (nobody can look)
    ///   - a live arm with no rows → `Ok(vec![])` (we looked, there is nothing)
    ///   - transport/401/`_ =>`    → `Unsupported`, carrying the crate's own
    ///     sentence (we could not look)
    ///
    /// The crate's fallthrough `_ => Ok(vec![])` at model_catalog.rs:522 is
    /// folded to `Unsupported` HERE and nowhere else: for the 13 unlisted
    /// prefixes it means "no standard models endpoint", which renders in a
    /// picker exactly like "this provider has no models" — the confusion the
    /// original doc named, arriving from the other direction. It is
    /// discriminated by arm membership, not by the empty vec, because an arm
    /// that legitimately returns zero rows must stay `Ok`.
    ///
    /// `base_url` remains an OLLAMA-ONLY input and the ollama arm does not
    /// delegate. `fetch_models` reads base URLs from `std::env::var` (12
    /// sites); a phone has no process environment the operator can set, so the
    /// one URL that cannot be defaulted — his own machine's — would be
    /// silently dropped by delegation. The cloud arms' env reads are
    /// overrides whose defaults are the real public endpoints, so they are
    /// correct unset. Parameterising them is a zeus-core cut, not this one.
    pub fn list_models(
        self: Arc<Self>,
        id: String,
        key: String,
        base_url: Option<String>,
    ) -> Result<Vec<String>, BridgeError> {
        let provider = resolve_provider(&id)?;
        if provider != Provider::Ollama {
            let models = self
                .rt
                .block_on(async { zeus_llm::fetch_models(&id, &key).await })
                .map_err(|e| {
                    // The crate's own sentence, not a summary of it: a 401
                    // says which key was refused and by whom, and a rewrite
                    // here would name the wrong subject.
                    BridgeError::Unsupported(e)
                })?;
            return classify_catalog_result(&id, provider.name(), models);
        }
        // The literal is gone. `unwrap_or(OLLAMA_DEFAULT_URL)` turned an absent
        // URL into `localhost:11434`, and on a phone THAT LOOPBACK IS THE PHONE
        // — nothing serves Ollama there, so the operator got a connection
        // failure four seconds later naming a host he never typed. An absent
        // input is refused at the door, with the subject named.
        let raw = base_url.as_deref().filter(|s| !s.trim().is_empty());
        let url = normalize_ollama_url(raw.ok_or(BridgeError::NoBaseUrl)?);
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

    /// Send `text` on `session_id` through the AGENT LOOP, streaming into `sink`.
    ///
    /// v1 called `client.stream(&messages, &[], None)` — and that empty second
    /// argument is the tool-schema slice, so the phone could not produce a tool
    /// call at all: the absence of tools was a LITERAL AT ONE CALL SITE, not a
    /// missing subsystem. This routes the turn through `zeus_agent::Agent`
    /// instead, which brings three things the direct call structurally could
    /// not have: tools, session history (`session.add` on both halves of the
    /// turn, agent_loop:1657/:2571), and the turn written back to memory.
    ///
    /// Blocks the calling thread, as before — Swift calls it off the main actor.
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

        let sessions_dir = self.sessions_dir.clone();
        let root = self.root.clone();
        let workspace = self.workspace.clone();
        // The model the operator ARMED, read off the live client. `Config` must
        // carry it because the loop reads `config.model` for routing decisions
        // (agent_loop:625, :2514) even though the `LlmClient` it is handed
        // already knows it — two readers, and `Config::default()` would give
        // the second one an EMPTY STRING (zeus-core:7152).
        let model = format!("{}/{}", client.provider().name(), client.model());
        let llm = (*client).clone();

        self.rt.block_on(async move {
            let config = build_config(&root, &sessions_dir, &model);
            let session = Session::resume_or_create(&sessions_dir, &session_id).await;
            let mut agent = Agent::new(config, llm, workspace, session, None);

            // D1: `message` is DENIED, and not because the channels argument is
            // `None`. With `None` the tool does not degrade — it returns an
            // explicit `Error::Tool` (tools.rs:1002-1017). Shipping its schema
            // would have the model CHOOSE it, burn an iteration, and be refused
            // by something it cannot tell from a transient failure. A tool that
            // can only fail is worse than an absent tool.
            //
            // The allow-list is the fail-closed form and the deny list is not
            // redundant: `is_tool_allowed` is DENY-FIRST, so the two names below
            // that are also absent from the allow-list are refused twice, and a
            // future tool added to the registry is refused by DEFAULT rather
            // than silently gained.
            agent.set_tool_policy(phone_tool_policy());

            let (tx, mut rx) = tokio::sync::mpsc::channel::<AgentEvent>(64);
            agent.set_events(tx);

            let turn = tokio::spawn(async move { agent.run_structured(&text).await });

            let full = match pump(&mut rx, sink.as_ref()).await {
                Some(full) => full,
                // `pump` already delivered `on_error`; the sink contract allows
                // exactly one terminal call, so this path must NOT fall through
                // to the `turn.await` arms below.
                None => return Ok(()),
            };

            match turn.await {
                Ok(Ok(result)) => {
                    // Prefer the turn's own content when non-empty, for the same
                    // reason v1 preferred the joined response: the events carry
                    // deltas, `TurnResult` carries the authoritative body.
                    let text = if result.content.is_empty() {
                        full
                    } else {
                        result.content
                    };
                    sink.on_complete(text);
                }
                Ok(Err(e)) => sink.on_error(e.to_string()),
                Err(e) => sink.on_error(format!("turn task failed: {e}")),
            }
            Ok(())
        })
    }

    /// The messages of one session, oldest first.
    ///
    /// D6: `sessions()` returned ids and there was no export returning a
    /// session's CONTENT, so "a session list that reopens a conversation" was
    /// unbuildable regardless of UI. `Session::export_markdown` exists and is
    /// the wrong shape — it is a document, and a transcript view needs rows.
    ///
    /// ── Why the tool name is a JOIN and not a field read ──
    ///
    /// The obvious prescription is "take the name from `tool_results[0]`".
    /// MEASURED at the pin, that is not buildable: `ToolResult` is
    /// `{ call_id, success, output }` — THERE IS NO NAME IN IT
    /// (`zeus-core/src/lib.rs:9492`). The name lives on `ToolCall`
    /// `{ id, name, arguments }` (`:9485`), and `agent_loop` persists the
    /// tool row with `tool_calls: vec![]` explicitly emptied. So the row
    /// `messages()` returns is NAME-FREE BY CONSTRUCTION, and a `tool_name`
    /// sourced that way would be `None` on every row — the same defect as
    /// the retired `SearchHit::line_number`: a field no producer can fill.
    ///
    /// The name survives one message EARLIER. Both persist sites add the
    /// assistant turn with `with_tool_calls(response.tool_calls.clone())`
    /// BEFORE the tool row (`:2599`→`:2906` and `:3099`→`:3116`), and
    /// `ToolResult::call_id` refers to `ToolCall::id`. So: carry the nearest
    /// preceding assistant message's calls, and match on the id.
    ///
    /// ── The ORDERING is the invariant, and it lives in a dependency ──
    ///
    /// "Nearest PRECEDING assistant" is correct only because `session.add`
    /// is called in that order at two independent sites in `zeus-agent`.
    /// Nothing in the type system enforces it: swap those two statements at
    /// either site and this join silently returns `None` for every row while
    /// everything still compiles. That is why the leg set includes a
    /// TOOL-FIRST fixture — a re-pin that reorders the writes must be
    /// DETECTED here, not discovered as a cosmetic regression on a phone.
    ///
    /// Unmatched degrades to `None`. It never guesses: attributing a result
    /// to the wrong tool is worse than the generic marker, because the
    /// generic marker is visibly generic and a wrong name reads as fact.
    pub fn messages(self: Arc<Self>, session_id: String) -> Result<Vec<TurnMessage>, BridgeError> {
        let dir = self.sessions_dir.clone();
        self.rt.block_on(async move {
            let session = Session::load(&dir, &session_id).await?;
            Ok(flatten_messages(&session.messages))
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

    /// Append a fact to workspace memory, then RE-INDEX.
    ///
    /// D3, second half. Content tokens alone do not make a remembered fact
    /// findable: the index is built at `init`, so a fact written at 14:02 is
    /// invisible to `search` until the process restarts. Both halves or the
    /// NODES relabel stays blocked — a search field beside a memory write,
    /// each correct alone, produces a screen where you type the thing you just
    /// saved and get nothing.
    ///
    /// Re-scans the whole workspace rather than patching one entry: the fact
    /// lands INSIDE `MEMORY.md`, whose name never changes, so a targeted
    /// update would have to re-tokenise that file's content anyway. Five files
    /// deep, this is cheaper than the write that preceded it.
    pub fn remember(self: Arc<Self>, fact: String) -> Result<(), BridgeError> {
        self.rt
            .block_on(async { self.workspace.remember(&fact).await })?;
        let fresh = scan_workspace(&self.root);
        if let Ok(mut guard) = self.index.write() {
            *guard = fresh;
        }
        Ok(())
    }

    /// Search the workspace index — names AND content.
    ///
    /// **Contract, restated because it widened:** v1 indexed FILENAME TOKENS
    /// ONLY. `scan_workspace` called `FileEntry::new` and never
    /// `with_first_line`/`with_tags`, so the indexer's 2.0 and 1.0 weight tiers
    /// (indexer.rs:196-215) were structurally empty and every posting came from
    /// a file NAME. That is why the NODES field shipped as `FIND A FILE` in C1:
    /// labelled "memory search" it would have been a wired button over a lying
    /// label.
    ///
    /// Content tokens now ride `with_tags` (weight 2.0), so a fact appended by
    /// `remember` is findable in the same session that wrote it. Two apertures,
    /// both real: only the first **64 KiB** of a file is read
    /// (`read_text_head`), and at most 4,096 unique tokens per file are kept —
    /// a fact past either bound is not findable, and that is a narrower claim
    /// than "content is indexed".
    ///
    /// `with_first_line` is deliberately NOT called, and the 1.0 tier stays
    /// structurally empty. MEASURED: the indexer tokenises `first_line` with no
    /// de-duplication (indexer.rs:213-221), so a file whose first line repeats
    /// one word 500 times contributes 500 postings at 1.0 and outranks the file
    /// actually NAMED for that word at 3.0 — the leg
    /// `content_tokens_are_deduplicated_so_repetition_cannot_outrank_a_name`
    /// failed exactly that way on the first cut. Feeding content into a tier
    /// that cannot bound it re-introduces the unbounded-posting defect that
    /// de-duplicating the tags was cut to avoid. Consequence, stated: the
    /// `context` field of a `SearchHit` remains `None` — same ruling as
    /// `line_number`, a field no producer can honestly fill returns when a
    /// bounded content tier exists to fill it.
    ///
    /// The snapshot is refreshed on every `remember`; a file written by the
    /// LOOP is visible on the next `remember` or the next launch, which is
    /// stated here rather than discovered.
    pub fn search(self: Arc<Self>, query: String) -> Vec<SearchHit> {
        let Ok(index) = self.index.read() else {
            return Vec::new();
        };
        index
            .search(&query)
            .into_iter()
            .map(|r| SearchHit {
                path: r.entry.path,
                name: r.entry.name,
                score: r.score,
                context: r.context,
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
        self.index.read().map(|i| i.len() as u32).unwrap_or(0)
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
/// Fold the crate's two identical-looking empties into two different answers.
///
/// Extracted from `list_models` for one reason, and it is a testability
/// reason rather than a tidiness one: the fold's ONLY input that varies is an
/// empty `Vec` from a live arm, and a live arm requires the network. Inlined,
/// the branch was unreachable from any hermetic leg — a mutation deleting it
/// left the suite fully green, which I measured rather than assumed. A free
/// function takes the vector directly, so the decision is guardable without a
/// socket while the call site keeps exactly one expression.
fn classify_catalog_result(
    id: &str,
    name: &str,
    models: Vec<String>,
) -> Result<Vec<String>, BridgeError> {
    if models.is_empty() && !PREFIXES_WITH_A_LIVE_CATALOG.contains(&name) {
        // Not "the list is empty" — "this crate has no arm for you".
        return Err(BridgeError::Unsupported(format!(
            "{id} has no live model catalog — type a model name"
        )));
    }
    Ok(models)
}

/// The prefixes `zeus_llm::fetch_models` has a LIVE ARM for, at the pinned sha.
///
/// This exists to discriminate the crate's two identical-looking `Ok(vec![])`
/// returns: an arm that queried and got nothing, versus the `_ => Ok(vec![])`
/// fallthrough at model_catalog.rs:522 that never queried at all. The vector
/// cannot tell them apart; only membership can.
///
/// It is a DUPLICATE of a fact that lives in another crate, so it is pinned by
/// a test (`live_catalog_arms_match_the_crate`) that reads the dependency's
/// source at the checkout and fails when the two drift. A hand-maintained
/// mirror with no reader is how a new provider becomes silently unlistable.
const PREFIXES_WITH_A_LIVE_CATALOG: &[&str] = &[
    "anthropic",
    "openai",
    "ollama",
    "google",
    "groq",
    "openrouter",
    "glm-coding",
    "glm",
    "mimo",
    "kimi",
    "qwen",
    "xai",
    "sakana",
];

fn resolve_provider(id: &str) -> Result<Provider, BridgeError> {
    Provider::from_prefix(id)
        .ok_or_else(|| BridgeError::Core(format!("unrecognized provider prefix: {id}")))
}

/// The five tools the phone may run.
///
/// **Five of NINE, not of eight.** The core set at tools.rs:503-504 is
/// `read_file, write_file, edit_file, list_dir, shell, python_exec, web_fetch,
/// spawn, message` — nine names under a comment that says "the 8 essentials".
/// `python_exec` is the one neither seat named in the plan; there is no Python
/// on iOS, so it denies alongside `shell` and `spawn`.
///
/// This is an ALLOW list and that is load-bearing: `AgentToolPolicy` treats an
/// EMPTY allow list as "everything not denied" (zeus-core:4666-4683), so a
/// deny-list phone build silently gains every tool a future registry adds.
const PHONE_TOOLS: [&str; 5] = ["read_file", "write_file", "edit_file", "list_dir", "web_fetch"];

/// Denied explicitly, though the allow-list already excludes them.
///
/// Not redundant: `is_tool_allowed` is DENY-FIRST, so these are refused by two
/// independent clauses. If a later edit widens the allow list — the plausible
/// mistake, since "add a tool" reads as a one-line change — these four still
/// refuse. `message` is here for D1's reason: with `channels: None` it does not
/// degrade, it returns an explicit `Error::Tool` (tools.rs:1002-1017), and a
/// tool that can only fail is worse than an absent one because the model cannot
/// tell the refusal from a transient error and retries.
const PHONE_DENIED: [&str; 4] = ["shell", "spawn", "python_exec", "message"];

/// The one tool policy, built once and asserted by the D4 legs.
///
/// Extracted so the legs measure THE OBJECT THE LOOP IS HANDED. A test that
/// rebuilt the same struct literal would be a twin of the production policy and
/// would stay green through any edit to the real one — the re-implements-its-
/// subject shape. One body, two readers.
fn phone_tool_policy() -> zeus_core::AgentToolPolicy {
    zeus_core::AgentToolPolicy {
        allowed_tools: PHONE_TOOLS.iter().map(|s| s.to_string()).collect(),
        denied_tools: PHONE_DENIED.iter().map(|s| s.to_string()).collect(),
    }
}

/// Build the loop's `Config` FROM THE BRIDGE'S OWN ROOT — never `Config::default()`.
///
/// D9, and it is a silent-wrong-answer bug rather than a crash.
/// `Config::default()` (zeus-core:7152) roots `workspace` at `~/.zeus/workspace`
/// and returns an EMPTY STRING for the model. On iOS `home_dir()` resolves
/// inside the app container, so the path EXISTS and is writable — the loop would
/// operate on a second, parallel workspace, and a file the model wrote would be
/// invisible to `search` forever. Two workspaces, one app, no error.
///
/// `max_iterations` is 12 rather than the default: a phone turn that runs 50
/// tool iterations is a battery event the operator cannot cancel from the UI.
fn build_config(
    root: &std::path::Path,
    sessions_dir: &std::path::Path,
    model: &str,
) -> zeus_core::Config {
    zeus_core::Config {
        model: model.to_string(),
        workspace: root.to_path_buf(),
        sessions: sessions_dir.to_path_buf(),
        max_iterations: 12,
        ..Default::default()
    }
}

// `OLLAMA_DEFAULT_URL` was retired here. It was a COPY of zeus-llm:1018's
// literal — the crate exports no constant — and it encoded a premise that is
// true on a workstation and FALSE on a phone: that `localhost` is where a model
// server lives. `list_models` now refuses the absent URL as `NoBaseUrl`.
// `apply_base_url` never needed it: `None` there already meant "leave the
// environment alone", which is the core's default, not this crate's.

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
/// Returns `None` when it delivered `on_error` — the caller must then make NO
/// further terminal call, because `TokenSink` permits exactly one.
///
/// The event type changed with the loop: v1 pumped `String`, the agent emits
/// `AgentEvent`. Re-typing the free function rather than inlining the match
/// keeps the production path and the tested path the SAME code — an inlined
/// loop inside `send` is unreachable from a test, since reaching it needs a
/// live provider, a network, and a key.
async fn pump(rx: &mut tokio::sync::mpsc::Receiver<AgentEvent>, sink: &dyn TokenSink) -> Option<String> {
    let mut full = String::new();
    while let Some(ev) = rx.recv().await {
        match ev {
            AgentEvent::TextChunk(c) => {
                full.push_str(&c);
                sink.on_token(c);
            }
            // A tool call is TOKENS THE OPERATOR CAN SEE, not a silent pause.
            // Without this the phone renders nothing for the seconds a
            // `read_file` takes, which reads as a hang.
            AgentEvent::ToolCall { name, .. } => {
                let line = format!("\n[{}]\n", name.to_uppercase());
                full.push_str(&line);
                sink.on_token(line);
            }
            AgentEvent::Error(e) => {
                sink.on_error(e);
                return None;
            }
            _ => {}
        }
    }
    Some(full)
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
                let mut entry = FileEntry::new(&rel, name, meta.len());
                if let Some(text) = read_text_head(&path) {
                    entry = entry.with_line_count(text.lines().count());
                    let tokens = content_tokens(&text);
                    if !tokens.is_empty() {
                        entry = entry.with_tags(tokens);
                    }
                }
                index.add(entry);
            }
        }
    }

    index
}

/// Read at most `MAX_CONTENT_BYTES` of a file, or `None` if it is not text.
///
/// Bounded because the phone rebuilds this index on every `remember`: an
/// unbounded read of a workspace the LOOP has been writing into turns a
/// one-line memory write into a whole-disk read. 64 KiB is the aperture, and
/// it is stated rather than implied — a fact written past that offset in one
/// file is NOT findable, which is a smaller lie than "content is indexed"
/// with no bound at all.
///
/// Binary rejection is by NUL byte, not by extension: an extension allow-list
/// silently drops the extensionless files a workspace is full of (`AGENTS`,
/// `Makefile`), and `from_utf8` alone accepts a UTF-8-clean binary blob.
fn read_text_head(path: &std::path::Path) -> Option<String> {
    use std::io::Read;

    const MAX_CONTENT_BYTES: usize = 64 * 1024;

    let mut file = std::fs::File::open(path).ok()?;
    let mut buf = vec![0u8; MAX_CONTENT_BYTES];
    let n = file.read(&mut buf).ok()?;
    buf.truncate(n);
    if buf.contains(&0) {
        return None;
    }
    // Lossy, not strict: a 64 KiB cut can land mid-codepoint, and discarding a
    // whole file because its last byte is half a `—` indexes nothing for the
    // sake of one character.
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// Word tokens from file content, for `with_tags` (weight 2.0).
///
/// ## Why this exists, measured
///
/// `scan_workspace` called `FileEntry::new` only, so `tags` and `first_line`
/// were empty for every entry and the indexer's 2.0 and 1.0 tiers were
/// STRUCTURALLY empty — every posting came from a file NAME. A fact appended
/// by `remember` lands inside `MEMORY.md`, whose name never changes, so
/// re-indexing found it zero times: measured on host as
/// `remember("zebraquorum…")` then `search("zebraquorum")` = 0 hits, against a
/// POS of `search("MEMORY")` = 1.
///
/// De-duplicated and capped: the indexer pushes one posting per token
/// occurrence, so an un-deduplicated file of 8,000 words is 8,000 postings
/// scoring 2.0 each — one large file would outrank every filename for every
/// term it happens to contain. Unique tokens make the tier a
/// does-this-file-contain-the-word signal, which is what a search field over
/// five files needs.
fn content_tokens(text: &str) -> Vec<String> {
    const MAX_TOKENS: usize = 4096;

    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for raw in text.split(|c: char| !c.is_alphanumeric() && c != '_') {
        if raw.len() < 2 {
            continue;
        }
        let token = raw.to_lowercase();
        if seen.insert(token.clone()) {
            out.push(token);
            if out.len() >= MAX_TOKENS {
                break;
            }
        }
    }
    out
}

// ============================================================================
// Provider catalogue
// ============================================================================

/// One provider row for the picker: the wire id, the human label, and the
/// shape of credential it needs.
///
/// Three fields, not two: `id` is what `set_provider` takes and what gets
/// persisted; `label` is what a human reads. They are NOT interchangeable —
/// `Provider::name()` returns wire ids (`xiaomimimo`, `glm-coding`), which is
/// why the core grew `label()`. Rendering `id` in a picker row is a defect,
/// and keeping both here means Swift never has to choose (or title-case).
#[derive(uniffi::Record)]
pub struct ProviderInfo {
    pub id: String,
    pub label: String,
    pub shape: CredentialShape,
}

/// What the operator must supply for a provider, folded to what this app can
/// actually collect.
///
/// The core's `zeus_core::CredentialShape` has SIX variants; this has four.
/// The three multi-part shapes (`KeyAndEndpoint`, `AwsPair`,
/// `ServiceAccountFile`) fold into `Unsupported`, carrying the core's own
/// shape name as the reason. Deliberate: a single `SecureField` gated on a
/// bool would collect HALF an Azure or Bedrock credential and produce a
/// provider that cannot work, with no error until the first send. Listing
/// them disabled-with-a-reason is the honest render.
#[derive(uniffi::Enum, Debug, PartialEq, Eq)]
pub enum CredentialShape {
    /// Nothing to collect (GoogleGeminiCli — ambient OAuth).
    None,
    /// One API key. 21 of 26 providers.
    Key,
    /// A URL, not a secret (Ollama).
    Url,
    /// Cannot be collected by this app's v1 form. `reason` is the core's own
    /// shape name, so the disabled row can say WHY rather than just "no".
    Unsupported { reason: String },
}

/// Fold the core's six-variant shape into the four this app can render.
///
/// EXHAUSTIVE, no wildcard arm: the core declares `CredentialShape` without
/// `#[non_exhaustive]` precisely so a seventh variant is a compile error here
/// instead of a silently-wrong form on a phone. Do not add `_ =>`.
fn fold_shape(shape: CoreCredentialShape) -> CredentialShape {
    match shape {
        CoreCredentialShape::None => CredentialShape::None,
        CoreCredentialShape::ApiKey => CredentialShape::Key,
        CoreCredentialShape::Url => CredentialShape::Url,
        CoreCredentialShape::KeyAndEndpoint => CredentialShape::Unsupported {
            reason: "KeyAndEndpoint".to_string(),
        },
        CoreCredentialShape::AwsPair => CredentialShape::Unsupported {
            reason: "AwsPair".to_string(),
        },
        CoreCredentialShape::ServiceAccountFile => CredentialShape::Unsupported {
            reason: "ServiceAccountFile".to_string(),
        },
    }
}

/// Every provider the core knows, in the core's own order.
///
/// A free function, not a method: it reads no core state, so requiring a live
/// `ZeusCore` (and therefore a workspace on disk) to populate a picker would
/// be a false dependency — and, as `resolve_provider`'s doc comment records,
/// an `Arc<Self>` method is a call site the tests cannot reach.
///
/// Order is `Provider::ALL`, NOT sorted here: the core's array is the one
/// ordering guarded upstream (`provider_all_is_exhaustive`). Re-sorting in
/// the bridge would create a second ordering that can silently disagree.
#[uniffi::export]
pub fn list_providers() -> Vec<ProviderInfo> {
    Provider::ALL
        .iter()
        .map(|p| ProviderInfo {
            id: p.name().to_string(),
            label: p.label().to_string(),
            shape: fold_shape(p.credential_shape()),
        })
        .collect()
}

/// The credential shape for one provider id.
///
/// Errors on an unknown id through `resolve_provider` rather than answering
/// `None` — "this provider needs no credential" and "I have never heard of
/// this provider" are opposite facts and must not share a return value.
#[uniffi::export]
pub fn credential_shape(id: String) -> Result<CredentialShape, BridgeError> {
    Ok(fold_shape(resolve_provider(&id)?.credential_shape()))
}

/// The role/name flattening of `messages()`, separated so it is reachable
/// from a `#[test]` without a session file on disk. `messages()` is the
/// production caller; this carries the whole join.
///
/// It is a FREE function, not an associated one: uniffi refuses associated
/// functions inside an exported impl block — MEASURED, `error: associated
/// functions are not currently supported`. A private helper is not part of
/// the FFI surface, but the macro cannot know that.
fn flatten_messages(messages: &[zeus_core::Message]) -> Vec<TurnMessage> {
    // The nearest preceding assistant turn's calls. Reset on a user turn:
    // a new question means any unmatched calls from the previous turn are
    // no longer candidates, so a stale name cannot leak across turns.
    let mut pending_calls: Vec<zeus_core::ToolCall> = Vec::new();
    let mut out: Vec<TurnMessage> = Vec::new();

    for m in messages {
        match m.role {
            // System messages are the persona, not the conversation.
            // Rendering them would show the operator a prompt he did
            // not write, attributed to nobody.
            zeus_core::Role::System => continue,
            zeus_core::Role::Assistant => {
                pending_calls = m.tool_calls.clone();
            }
            zeus_core::Role::User => {
                pending_calls.clear();
            }
            zeus_core::Role::Tool => {}
        }

        let tool_name = if matches!(m.role, zeus_core::Role::Tool) {
            m.tool_results.first().and_then(|r| {
                pending_calls
                    .iter()
                    .find(|c| c.id == r.call_id)
                    .map(|c| c.name.clone())
            })
        } else {
            None
        };

        out.push(TurnMessage {
            role: match m.role {
                zeus_core::Role::User => "user",
                zeus_core::Role::Assistant => "assistant",
                zeus_core::Role::Tool => "tool",
                zeus_core::Role::System => "system",
            }
            .to_string(),
            content: m.content.clone(),
            timestamp_rfc3339: m.timestamp.to_rfc3339(),
            tool_name,
        });
    }

    out
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

    /// Zeus100's host probe, as a standing leg.
    ///
    /// The claim that failed: the `search` doc, the docs table and my own post
    /// all said content tokens landed, while `scan_workspace` still called
    /// `FileEntry::new` only. Measured on host: `remember("zebraquorum…")` then
    /// `search("zebraquorum")` = 0 hits against a POS of `search("MEMORY")` = 1.
    /// Re-indexing cannot find a fact inside a file whose NAME never changes.
    ///
    /// Three arms, and the NEG is the one that makes the other two mean
    /// anything: an index that scored every file for every query passes both
    /// the content hit and the filename POS.
    #[test]
    fn remembered_fact_is_findable_by_content() {
        let dir = std::env::temp_dir().join(format!("zcb-content-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let core = ZeusCore::init(dir.to_string_lossy().to_string()).unwrap();

        core.clone().remember("zebraquorum is the probe token".to_string()).unwrap();

        let hits = core.clone().search("zebraquorum".to_string());
        assert_eq!(
            hits.len(),
            1,
            "a token written INSIDE MEMORY.md must be findable by content"
        );
        assert!(
            hits[0].path.ends_with("MEMORY.md"),
            "the hit must be the file the fact landed in, got {}",
            hits[0].path
        );

        // POS: the filename tier still works, so a content-tier regression is
        // distinguishable from the index being empty.
        assert!(
            !core.clone().search("MEMORY".to_string()).is_empty(),
            "filename tier must still score"
        );

        // NEG: a token never written anywhere.
        assert!(
            core.clone().search("quetzalcoatl".to_string()).is_empty(),
            "a token in no file must score nothing"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The 64 KiB aperture is a real boundary, so it gets a leg on both sides.
    ///
    /// Without the far arm this is a test of the near arm only, and a bound
    /// silently raised to `usize::MAX` (an unbounded read of a workspace the
    /// loop writes into) would pass.
    #[test]
    fn content_index_respects_the_64_kib_aperture() {
        let dir = std::env::temp_dir().join(format!("zcb-aperture-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let mut body = String::from("nearsentinel\n");
        while body.len() < 70 * 1024 {
            body.push_str("filler filler filler\n");
        }
        body.push_str("farsentinel\n");
        std::fs::write(dir.join("big.md"), &body).unwrap();

        let index = scan_workspace(&dir);
        assert_eq!(index.search("nearsentinel").len(), 1, "inside the aperture");
        assert!(
            index.search("farsentinel").is_empty(),
            "past 64 KiB is NOT indexed — the bound is real and stated"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A binary file must not enter the content tier.
    ///
    /// NUL rejection, not an extension allow-list: a workspace is full of
    /// extensionless text files and `from_utf8` alone accepts a UTF-8-clean
    /// blob. POS arm asserts the file is still INDEXED BY NAME — rejecting its
    /// content must not drop it from the index.
    #[test]
    fn binary_files_are_named_but_not_content_indexed() {
        let dir = std::env::temp_dir().join(format!("zcb-binary-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("blob.bin"), b"opaquetoken\x00\x01\x02more").unwrap();

        let index = scan_workspace(&dir);
        assert_eq!(index.len(), 1, "the file is still indexed");
        assert_eq!(index.search("blob").len(), 1, "POS: by NAME");
        assert!(
            index.search("opaquetoken").is_empty(),
            "a token inside a binary must not enter the content tier"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Content tokens are de-duplicated, and this is a ranking property not a
    /// cosmetic one.
    ///
    /// The indexer pushes one posting per token occurrence at weight 2.0, so an
    /// un-deduplicated file repeating a word 500 times scores 1,000 for it and
    /// outranks the file actually NAMED for it (3.0). The leg asserts the
    /// ordering, which is the observable a search field renders.
    #[test]
    fn content_tokens_are_deduplicated_so_repetition_cannot_outrank_a_name() {
        let dir = std::env::temp_dir().join(format!("zcb-dedup-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("runbook.md"), "deploy steps").unwrap();
        std::fs::write(dir.join("noise.md"), "runbook ".repeat(500)).unwrap();

        let index = scan_workspace(&dir);
        let hits = index.search("runbook");
        assert_eq!(hits.len(), 2, "both files match");
        assert!(
            hits[0].entry.path.ends_with("runbook.md"),
            "the file NAMED runbook must outrank the file that repeats it, got {}",
            hits[0].entry.path
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
    ///
    /// `errors` exists so the error leg can assert the sink was called ONCE
    /// with the right message — a bool would prove arrival and hide a double
    /// terminal call, which is the exact contract `pump`'s `None` protects.
    #[derive(Default)]
    struct Recorder {
        tokens: std::sync::Mutex<Vec<String>>,
        errors: std::sync::Mutex<Vec<String>>,
    }
    impl TokenSink for Recorder {
        fn on_token(&self, token: String) {
            self.tokens.lock().unwrap().push(token);
        }
        fn on_complete(&self, _full_text: String) {}
        fn on_error(&self, message: String) {
            self.errors.lock().unwrap().push(message);
        }
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
            let (tx, mut rx) = tokio::sync::mpsc::channel::<AgentEvent>(8);
            tokio::spawn(async move {
                for t in ["Zeus ", "core ", "is ", "live"] {
                    tx.send(AgentEvent::TextChunk(t.to_string())).await.unwrap();
                }
                // Drop closes the channel; the pump must terminate on close,
                // not hang. A pump that never returned would fail this test by
                // timeout rather than by assertion — which is why the sender is
                // dropped explicitly here instead of relying on scope exit.
                drop(tx);
            });

            let sink = Recorder::default();
            let full = pump(&mut rx, &sink).await.expect("clean close yields Some");

            assert_eq!(full, "Zeus core is live", "accumulated text");
            let seen = sink.tokens.lock().unwrap().clone();
            assert_eq!(
                seen,
                vec!["Zeus ", "core ", "is ", "live"],
                "every token forwarded, in order"
            );

            // Vacuity: assert the two things this test claims DIFFER actually
            // do. If `pump` forwarded nothing, `seen` and the empty vec would
            // both be empty and the equality above would still be checked
            // against a literal — so pin non-emptiness explicitly.
            assert_ne!(seen.len(), 0, "sink received tokens at all");
            assert!(
                sink.errors.lock().unwrap().is_empty(),
                "a clean close must not deliver on_error"
            );
        });
    }

    /// The error leg. `AgentEvent::Error` must deliver `on_error` and return
    /// `None`, because the caller uses `None` to suppress its own terminal
    /// call — `TokenSink` permits exactly one, and a double call is invisible
    /// to a sink that only records a bool.
    #[test]
    fn pump_reports_error_once_and_returns_none() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let (tx, mut rx) = tokio::sync::mpsc::channel::<AgentEvent>(8);
            tokio::spawn(async move {
                tx.send(AgentEvent::TextChunk("partial ".to_string()))
                    .await
                    .unwrap();
                tx.send(AgentEvent::Error("provider refused".to_string()))
                    .await
                    .unwrap();
                // Deliberately NOT dropped early: tokens after the error must
                // not be forwarded, which only means something if the sender
                // is still live when `pump` returns.
                tx.send(AgentEvent::TextChunk("after ".to_string()))
                    .await
                    .ok();
            });

            let sink = Recorder::default();
            let out = pump(&mut rx, &sink).await;

            assert!(out.is_none(), "error leg returns None so caller stays silent");
            let errs = sink.errors.lock().unwrap().clone();
            assert_eq!(errs, vec!["provider refused"], "exactly one error, verbatim");
            let seen = sink.tokens.lock().unwrap().clone();
            assert_eq!(seen, vec!["partial "], "no token forwarded after the error");
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

    #[test]
    fn live_catalog_arms_match_the_crate() {
        let rev = env!("CARGO_PKG_NAME"); // placeholder; the pin is read below
        let _ = rev;
        let home = match std::env::var("HOME") {
            Ok(h) => h,
            Err(_) => return,
        };
        // The pin, read from THIS crate's manifest rather than retyped: a
        // hardcoded sha here would be a third copy of the same fact.
        let manifest = include_str!("../Cargo.toml");
        let pin = manifest
            .lines()
            .find_map(|l| {
                let l = l.trim();
                if l.starts_with("zeus-llm") {
                    l.split("rev = \"").nth(1)?.split('"').next()
                } else {
                    None
                }
            })
            .expect("zeus-llm's rev must be readable from the manifest");
        assert_eq!(pin.len(), 40, "the manifest must pin a full 40-char rev");

        let short = &pin[..7];
        let base = std::path::Path::new(&home).join(".cargo/git/checkouts");
        let mut source: Option<String> = None;
        if let Ok(dirs) = std::fs::read_dir(&base) {
            for d in dirs.flatten() {
                let candidate = d
                    .path()
                    .join(short)
                    .join("crates/zeus-llm/src/model_catalog.rs");
                if let Ok(text) = std::fs::read_to_string(&candidate) {
                    source = Some(text);
                    break;
                }
            }
        }
        let Some(source) = source else {
            eprintln!("SKIP live_catalog_arms_match_the_crate: no checkout for {short}");
            return;
        };

        // A POSITIVE CONTROL on the parse itself. If the match-arm shape ever
        // changes, this derivation yields an empty set and the comparison
        // below would then be measuring nothing while looking rigorous.
        // Derivation by ARM BODY, not by arm presence — the distinction the
        // first run of this leg taught me. `model_catalog.rs:315` is
        // `"minimax-coding" | "qwen-coding" => Ok(vec![])`: a named arm that
        // is semantically the FALLTHROUGH, returning empty without querying.
        // Counting it as live would have told the phone to expect a list from
        // a provider the crate never asks about — the exact confusion this
        // constant exists to prevent, arriving through the instrument meant
        // to detect it. An or-pattern also hides a second prefix behind the
        // first, so alternatives are split rather than read as one name.
        let mut found: Vec<String> = Vec::new();
        let mut in_match = false;
        for line in source.lines() {
            if line.contains("match provider.name()") {
                in_match = true;
                continue;
            }
            if !in_match {
                continue;
            }
            let t = line.trim();
            if t.starts_with("_ =>") {
                break;
            }
            let Some((head, body)) = t.split_once("=>") else {
                continue;
            };
            if !head.trim_start().starts_with('"') {
                continue;
            }
            // An arm whose body IS the empty vector never reaches the network.
            if body.replace(' ', "").starts_with("Ok(vec![])") {
                continue;
            }
            for alt in head.split('|') {
                if let Some(rest) = alt.trim().strip_prefix('"') {
                    if let Some(name) = rest.split('"').next() {
                        found.push(name.to_string());
                    }
                }
            }
        }
        assert!(
            found.len() > 5,
            "the arm parse yielded {} names — the source shape changed and this \
             leg is no longer measuring anything",
            found.len()
        );

        // A NEGATIVE CONTROL on the body filter. If the filter silently stops
        // firing, the assertion above still passes and the set merely grows —
        // so the arm that MUST be excluded is named explicitly.
        assert!(
            !found.iter().any(|n| n == "minimax-coding"),
            "an arm returning Ok(vec![]) without querying is not a live catalog"
        );

        let mut mine: Vec<String> = PREFIXES_WITH_A_LIVE_CATALOG
            .iter()
            .map(|s| s.to_string())
            .collect();
        mine.sort();
        found.sort();
        assert_eq!(
            found, mine,
            "the mirror has drifted from the crate: a provider gained or lost a \
             live catalog arm upstream and the phone still believes the old set"
        );
    }

    /// The fold turns ONE empty vector into TWO different answers, and the
    /// discriminator is arm membership rather than the vector.
    ///
    /// This leg exists because a mutation proved the branch unguarded: with
    /// the fold deleted the whole suite stayed green, since every hermetic
    /// path refuses before reaching it. An arm that genuinely has zero models
    /// today must stay `Ok` — folding THAT to a refusal would tell the
    /// operator his key is bad when the catalog is merely empty.
    #[test]
    fn an_empty_list_means_two_different_things() {
        // Live arm, nothing returned: we looked, there is nothing. Ok.
        match classify_catalog_result("anthropic", "anthropic", vec![]) {
            Ok(v) => assert!(v.is_empty(), "a live arm's empty list stays an empty list"),
            other => panic!("a live arm returning zero models must stay Ok, got {other:?}"),
        }
        // No arm: the crate never queried. A typed refusal, naming the id.
        match classify_catalog_result("minimax-coding", "minimax-coding", vec![]) {
            Err(BridgeError::Unsupported(msg)) => assert!(
                msg.contains("minimax-coding"),
                "the refusal must name the id the caller passed, got {msg}"
            ),
            other => panic!("an armless prefix must refuse, got {other:?}"),
        }
        // Non-empty is never touched, whatever the membership.
        let rows = vec!["m1".to_string()];
        assert_eq!(
            classify_catalog_result("minimax-coding", "minimax-coding", rows.clone()).unwrap(),
            rows,
            "a populated list is returned regardless of the mirror"
        );
        // VACUITY: the two empty cases must not be the same answer.
        assert_ne!(
            format!("{:?}", classify_catalog_result("anthropic", "anthropic", vec![])),
            format!("{:?}", classify_catalog_result("minimax-coding", "minimax-coding", vec![])),
            "one empty vector must yield two distinguishable outcomes"
        );
    }

    /// An unknown prefix, a keyless live arm, and the ollama path stay three
    /// DIFFERENT answers.
    ///
    /// The old leg asserted `anthropic` is `Unsupported`; that was the policy
    /// and the policy changed, so the leg is rewritten rather than deleted —
    /// what must survive is that the three outcomes do not collapse into one.
    /// No network: the unknown-prefix arm is refused before any request, and
    /// ollama-without-a-URL is refused at the door.
    #[test]
    fn the_three_listing_outcomes_stay_distinct() {
        // ENV_LOCK, and NOT for the environment. `ZeusCore::init` installs the
        // process-global workspace root (`set_workspace_root`), so any two
        // init-ing legs on cargo's thread pool race for it — and the loser is
        // the SANDBOX leg, which then writes its probe file under another
        // test's root and fails with a message about a missing file. Measured:
        // 3 red in 6 identical runs before this line, 0 in 6 after. The mutex
        // is the only serialisation available for a global that has no
        // per-instance form, and the doc above it names OLLAMA_HOST because
        // that was the first global to need it, not the only one.
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("zcb-list3-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let core = ZeusCore::init(dir.to_string_lossy().to_string()).unwrap();

        // 1. Nobody can look: the prefix is not a provider at all.
        match core.clone().list_models("nosuchprovider".into(), "k".into(), None) {
            Err(BridgeError::Core(msg)) => assert!(
                msg.contains("nosuchprovider"),
                "an unknown prefix is a Core error naming it"
            ),
            other => panic!("expected Core for an unknown prefix, got {other:?}"),
        }

        // 2. Ollama does NOT delegate and keeps its own refusal: base_url is
        //    the one input the environment cannot supply on a phone.
        match core.clone().list_models("ollama".into(), String::new(), None) {
            Err(BridgeError::NoBaseUrl) => {}
            other => panic!("ollama without a URL must stay NoBaseUrl, got {other:?}"),
        }

        // 3. The two refusals are not the same refusal. Without this the two
        //    arms above could both be `Core` and read as passing.
        let unknown = core.clone().list_models("nosuchprovider".into(), "k".into(), None);
        let ollama = core.clone().list_models("ollama".into(), String::new(), None);
        assert_ne!(
            format!("{unknown:?}"),
            format!("{ollama:?}"),
            "the two refusals must be distinguishable by the caller"
        );

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

    // ------------------------------------------------------------------
    // Provider catalogue
    // ------------------------------------------------------------------

    /// The row count is the core's count, and the ids are the core's ids.
    ///
    /// Asserts against `Provider::ALL` rather than the literal 26: pinning the
    /// number here would make a legitimate core addition fail as though the
    /// bridge were broken, and pinning it in BOTH places is one fact expressed
    /// twice. The count that matters is upstream, where the wildcard-free
    /// match guards it.
    #[test]
    fn list_providers_is_the_cores_list_in_the_cores_order() {
        let rows = list_providers();
        assert_eq!(rows.len(), Provider::ALL.len());

        let ids: Vec<&str> = rows.iter().map(|r| r.id.as_str()).collect();
        let core: Vec<&str> = Provider::ALL.iter().map(|p| p.name()).collect();
        assert_eq!(ids, core, "order and ids must be the core's, unsorted");
    }

    /// The row carries a LABEL, not a second copy of the id.
    ///
    /// This is the leg that fails if someone "simplifies" `ProviderInfo` to one
    /// string: `label` and `id` must differ for at least one provider, and the
    /// named example is the one that motivated `Provider::label()` existing.
    /// A vacuity assert, not a style check — a picker rendering `xiaomimimo`
    /// is the defect this whole field exists to prevent.
    #[test]
    fn label_is_not_the_wire_id() {
        let rows = list_providers();
        let differing = rows.iter().filter(|r| r.id != r.label).count();
        assert!(
            differing > 0,
            "no row's label differs from its id — label() is not being read"
        );

        let mimo = rows
            .iter()
            .find(|r| r.id == "xiaomimimo")
            .expect("the core's ALL must still contain xiaomimimo");
        assert_ne!(
            mimo.label, mimo.id,
            "the row that motivated label() must not render its wire id"
        );
    }

    /// The fold is not constant, and each arm is the arm it claims.
    ///
    /// Four distinct outputs asserted by NAME, because a fold that returned
    /// `Key` for everything would pass any count-based check and would render
    /// a key field for Ollama (a URL) and for GoogleGeminiCli (nothing).
    #[test]
    fn fold_maps_each_core_shape_to_its_own_arm() {
        assert_eq!(fold_shape(CoreCredentialShape::None), CredentialShape::None);
        assert_eq!(fold_shape(CoreCredentialShape::ApiKey), CredentialShape::Key);
        assert_eq!(fold_shape(CoreCredentialShape::Url), CredentialShape::Url);

        for (core, name) in [
            (CoreCredentialShape::KeyAndEndpoint, "KeyAndEndpoint"),
            (CoreCredentialShape::AwsPair, "AwsPair"),
            (CoreCredentialShape::ServiceAccountFile, "ServiceAccountFile"),
        ] {
            match fold_shape(core) {
                CredentialShape::Unsupported { reason } => assert_eq!(reason, name),
                other => panic!("{name} must fold to Unsupported, got {other:?}"),
            }
        }
    }

    /// Named providers land in the arm the operator experience depends on.
    ///
    /// Ollama is `Url` (the picker shows a host field, never a key field) and
    /// Anthropic is `Key`; asserting both in one leg means a fold that
    /// collapsed to a single arm cannot pass. Azure carries its reason string
    /// because a disabled row with no reason is just a broken row.
    #[test]
    fn credential_shape_answers_per_provider_not_uniformly() {
        assert_eq!(credential_shape("ollama".to_string()).unwrap(), CredentialShape::Url);
        assert_eq!(
            credential_shape("anthropic".to_string()).unwrap(),
            CredentialShape::Key
        );
        assert_ne!(
            credential_shape("ollama".to_string()).unwrap(),
            credential_shape("anthropic".to_string()).unwrap(),
            "two providers with different core shapes must not fold to one answer"
        );
        match credential_shape("azure".to_string()).unwrap() {
            CredentialShape::Unsupported { reason } => assert_eq!(reason, "KeyAndEndpoint"),
            other => panic!("azure must be Unsupported, got {other:?}"),
        }
    }

    /// An unknown id is an ERROR, never `None`.
    ///
    /// `None` means "this provider needs no credential" — answering it for a
    /// typo would render a working-looking row for a provider that does not
    /// exist. Same defect family as #559, one surface over.
    #[test]
    fn credential_shape_refuses_an_unknown_id() {
        // Positive control: the function resolves a real id at all.
        assert!(credential_shape("groq".to_string()).is_ok());

        let err = credential_shape("nosuchprovider".to_string())
            .expect_err("unknown id must error, never answer None");
        assert!(
            matches!(&err, BridgeError::Core(m) if m.contains("nosuchprovider")),
            "the error must name the offending id, got: {err}"
        );
    }

    /// The group sizes the picker's navigation argument rests on.
    ///
    /// Recorded as a test because the shape of the UI (search-first, two
    /// one-row groups above a 21-row wall) was ruled ON these numbers. If the
    /// core's table shifts them, the ruling deserves re-examination rather
    /// than silently becoming wrong — so this leg is a tripwire on a design
    /// premise, not a correctness check.
    #[test]
    fn credential_shape_group_sizes_match_the_ruled_picker_layout() {
        let rows = list_providers();
        let count = |want: &CredentialShape| rows.iter().filter(|r| &r.shape == want).count();
        assert_eq!(count(&CredentialShape::Key), 21, "Key group");
        assert_eq!(count(&CredentialShape::Url), 1, "Url group (ollama)");
        assert_eq!(count(&CredentialShape::None), 1, "None group (gemini-cli)");
        assert_eq!(
            rows.iter()
                .filter(|r| matches!(r.shape, CredentialShape::Unsupported { .. }))
                .count(),
            3,
            "Unsupported group (azure, bedrock, vertex)"
        );
    }

    // ========================================================================
    // D4 — the tool policy, measured at the policy object the loop is handed.
    //
    // My own walk proposed a different leg: "ask for `shell` explicitly, assert
    // no tool call". RETRACTED before it shipped. The policy FILTERS THE SCHEMAS
    // (agent_loop:2155) before the model is prompted, so the model is never told
    // `shell` exists and will not ask for it. That leg passes with the deny path
    // never executing — it measures the model's vocabulary, not our guard.
    // ========================================================================

    /// The policy the bridge builds refuses every denied name.
    ///
    /// `is_tool_allowed` is DENY-FIRST (zeus-core:4737), which is why the four
    /// denied names appear in `denied_tools` even though the allow-list already
    /// omits them: absence relies on the allow-list staying non-empty, and an
    /// EMPTY allow-list means everything.
    #[test]
    fn phone_policy_refuses_every_denied_name() {
        let policy = phone_tool_policy();
        // The names are written OUT, not read from `PHONE_DENIED`. A needle
        // derived from its own subject cannot see the subject vanish: emptying
        // the constant makes `for name in PHONE_DENIED` iterate ZERO times and
        // this leg passes green over a policy that denies nothing. Measured —
        // that mutation left only the arity leg red.
        for name in ["shell", "spawn", "python_exec", "message"] {
            assert!(!policy.is_tool_allowed(name), "{name} must be refused on a phone");
        }
        // Vacuity: a policy that refused EVERYTHING passes the loop above while
        // breaking the product. The allowed set must still be allowed.
        for name in PHONE_TOOLS {
            assert!(policy.is_tool_allowed(name), "{name} is the product and must be allowed");
        }
    }

    /// A tool added to the registry LATER is refused by default, not gained.
    #[test]
    fn an_unknown_future_tool_is_refused_by_default() {
        let policy = phone_tool_policy();
        assert!(
            !policy.is_tool_allowed("ZZZ_FUTURE_TOOL_XYZ"),
            "a name in neither list must be refused, not gained"
        );
    }

    /// The allowed set is EXACTLY the five ruled names — no more, no fewer.
    ///
    /// Arity leg. Without it, adding a sixth name to `PHONE_TOOLS` passes every
    /// membership assertion above: they all ask "is this allowed", none asks
    /// "what else is".
    #[test]
    fn the_allowed_set_is_exactly_the_five_ruled_names() {
        let policy = phone_tool_policy();
        let mut got: Vec<&str> = policy.allowed_tools.iter().map(|s| s.as_str()).collect();
        got.sort_unstable();
        assert_eq!(
            got,
            ["edit_file", "list_dir", "read_file", "web_fetch", "write_file"],
            "the five ruled names, sorted"
        );
        assert_eq!(policy.allowed_tools.len(), 5, "arity");
        assert_eq!(policy.denied_tools.len(), 4, "denied arity");
    }

    /// D: the workspace-root guard, measured through THIS crate's production
    /// caller of `set_workspace_root` — not through a hand-set root.
    ///
    /// WHY IT LIVES IN RUST AND NOT ON THE SIMULATOR. The ruled shape was a
    /// Swift leg asserting `read_file("../x")` is refused on the phone. It has
    /// no surface to run on: `ZeusCore` exports ten things and none executes a
    /// tool by name, so the only Swift route into `validate_tool_path` is a
    /// LIVE MODEL choosing `read_file`. That makes the "escape leg" a network
    /// call inside a unit suite — non-hermetic, red on a box with no key, and
    /// a flake wearing a test's name. This leg takes the same measurement with
    /// no model in the loop: `ZeusCore::init` is the production caller, and
    /// `ToolRegistry::with_defaults()` is the same registry the agent builds.
    ///
    /// The assertions are on the guard's OWN message, not on `is_err`. Two
    /// different rules in `validate_tool_path` refuse `../outside.txt`: the
    /// pre-existing traversal rule ("Path traversal denied") and the root
    /// confinement landed as `5ec2c557` ("outside workspace root"). An
    /// `is_err()` assertion passes under either, so it cannot see the root
    /// guard vanish — which is exactly what the mutation arm does.
    #[test]
    fn workspace_root_confines_the_phone_file_tools() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

        let dir = std::env::temp_dir().join(format!("zcb-d-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // A real file OUTSIDE the root, one level up. Its existence is the
        // point: a refusal for "no such file" would be the right verdict for
        // the wrong reason, and indistinguishable from the guard working.
        let outside = dir.parent().unwrap().join(format!(
            "zcb-d-outside-{}.txt",
            std::process::id()
        ));
        std::fs::write(&outside, "secret").unwrap();

        let core = ZeusCore::init(dir.to_string_lossy().to_string()).expect("init");
        let registry = zeus_agent::tools::ToolRegistry::with_defaults();
        let rt = tokio::runtime::Runtime::new().unwrap();

        let needle = "outside ".to_owned() + "workspace root";

        // NEG 1: a relative escape.
        let rel = format!("../{}", outside.file_name().unwrap().to_string_lossy());
        let err = rt
            .block_on(registry.execute("read_file", serde_json::json!({ "path": rel })))
            .expect_err("a relative escape must be refused");
        assert!(
            err.to_string().contains(&needle),
            "must be refused BY THE ROOT GUARD, got: {err}"
        );

        // NEG 2: an absolute path outside. The traversal rule cannot fire here
        // (no `..` to pop), so this arm isolates the confinement check.
        let abs = outside.to_string_lossy().to_string();
        let err = rt
            .block_on(registry.execute("read_file", serde_json::json!({ "path": abs })))
            .expect_err("an absolute path outside the root must be refused");
        assert!(
            err.to_string().contains(&needle),
            "absolute outside, got: {err}"
        );

        // POS: a path INSIDE is served, and lands on disk under the canonical
        // root. Without this arm a guard that refuses EVERYTHING passes both
        // negatives — the failure mode that makes the phone's file tools inert
        // while looking maximally secure.
        rt.block_on(registry.execute(
            "write_file",
            serde_json::json!({ "path": "probefile.txt", "content": "inside" }),
        ))
        .expect("a path inside the root must be served");

        let written = core.root.join("probefile.txt");
        assert!(written.exists(), "the served write must be on disk at {written:?}");
        assert!(
            written.starts_with(&core.root),
            "and under the canonical root"
        );

        // The round trip that proves loop and index share ONE root: a fact
        // remembered through the core is found by the core's own search.
        core.clone()
            .remember("dromedaryquorum is the D leg's token".to_string())
            .expect("remember");
        assert!(
            !core.clone().search("dromedaryquorum".to_string()).is_empty(),
            "a remembered fact must be findable — one root, or this is empty"
        );

        let _ = std::fs::remove_file(&outside);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ========================================================================
    // The tool-name join (replay `[READ_FILE]` vs live `[TOOL]`)
    // ========================================================================

    /// Build a `zeus_core::Message` for the join fixtures. The timestamp is
    /// fixed so ordering here is STATEMENT order, which is the property under
    /// test — a clock would let two rows tie and hide a reordering.
    /// A persisted tool row, built through the CORE'S OWN constructor rather
    /// than a struct literal. `Message::tool` sets `content: String::new()`
    /// and `tool_calls: vec![]` itself (`zeus-core:9483`) — the exact shape
    /// `agent_loop` writes. A literal here would let me write a tool row the
    /// loop never produces and then pass a test about it. (`Message` has no
    /// `Default`, MEASURED: `the trait bound Message: Default is not
    /// satisfied` — which is how this fixture got corrected.)
    fn tool_row(call_id: &str) -> zeus_core::Message {
        zeus_core::Message::tool(call_id, true, "")
    }

    /// An assistant turn carrying calls, through `with_tool_calls` — the same
    /// builder both persist sites use (`:2599`, `:3099`).
    fn assistant_with(calls: Vec<zeus_core::ToolCall>) -> zeus_core::Message {
        zeus_core::Message::assistant("").with_tool_calls(calls)
    }

    fn call(id: &str, name: &str) -> zeus_core::ToolCall {
        zeus_core::ToolCall {
            id: id.to_string(),
            name: name.to_string(),
            arguments: serde_json::json!({}),
        }
    }

    /// LEG 1 — the ordinary case: assistant-then-tool recovers the name.
    ///
    /// This is the leg the whole cut exists for. Note the tool row's content
    /// is EMPTY and its `tool_calls` is EMPTY, exactly as `agent_loop`
    /// persists it — a fixture that filled either would be testing a message
    /// the loop never writes.
    #[test]
    fn a_matched_tool_row_recovers_its_name() {
        let rows = flatten_messages(&[
            zeus_core::Message::user("list my files"),
            assistant_with(vec![call("c1", "read_file")]),
            tool_row("c1"),
        ]);

        assert_eq!(rows.len(), 3, "no row may be dropped by the join");
        assert_eq!(rows[2].role, "tool");
        assert_eq!(
            rows[2].tool_name.as_deref(),
            Some("read_file"),
            "the name lives on the PRECEDING assistant turn and must be joined \
             through call_id -> id"
        );
        // The non-tool rows must stay None: a join that stamped every row
        // would satisfy the assertion above while being wrong everywhere else.
        assert_eq!(rows[0].tool_name, None, "a user row has no tool name");
        assert_eq!(rows[1].tool_name, None, "an assistant row has no tool name");
    }

    /// LEG 2 — no matching `call_id` degrades, and NEVER mis-attributes.
    ///
    /// The assistant turn here carries a call, so the join has a candidate
    /// available; only the id fails to match. A join that took
    /// `pending_calls[0]` positionally instead of matching would pass leg 1
    /// and fail here — which is the only reason this leg carries a populated
    /// assistant turn rather than an empty one.
    #[test]
    fn an_unmatched_tool_row_degrades_rather_than_guessing() {
        let rows = flatten_messages(&[
            assistant_with(vec![call("c1", "read_file")]),
            tool_row("MISMATCH"),
        ]);

        assert_eq!(rows[1].role, "tool");
        assert_eq!(
            rows[1].tool_name, None,
            "an unmatched call_id must degrade to the generic marker; a \
             positional guess would name the wrong tool and read as fact"
        );
    }

    /// LEG 3 — TOOL-FIRST ordering degrades.
    ///
    /// This is the durable half of the set and it looks redundant until you
    /// know why it is here: "nearest PRECEDING assistant" is correct only
    /// because `session.add` is called assistant-then-tool at two independent
    /// sites in a PINNED DEPENDENCY (`:2599`->`:2906`, `:3099`->`:3116`).
    /// Nothing enforces that. A re-pin that swaps those statements breaks the
    /// join silently and compiles perfectly. This leg is the compiler for an
    /// invariant that otherwise lives only in a comment.
    #[test]
    fn a_tool_row_before_its_assistant_turn_degrades() {
        let rows = flatten_messages(&[
            tool_row("c1"),
            assistant_with(vec![call("c1", "read_file")]),
        ]);

        assert_eq!(rows[0].role, "tool");
        assert_eq!(
            rows[0].tool_name, None,
            "a tool row written BEFORE its assistant turn must not be named \
             from a LATER message — if this leg reds, the dependency changed \
             its write order and the join needs re-deriving, not patching"
        );
        // Vacuity guard: leg 1 and leg 3 differ only in statement order, so
        // assert they actually disagree. If both were None the set would be
        // green while measuring nothing.
        let ordered = flatten_messages(&[
            assistant_with(vec![call("c1", "read_file")]),
            tool_row("c1"),
        ]);
        assert_ne!(
            ordered[1].tool_name, rows[0].tool_name,
            "the two orderings MUST render differently or this leg is vacuous"
        );
    }

    /// LEG 4 — a new user turn clears the candidates.
    ///
    /// Without the reset, an unmatched tool row in turn 2 could be named from
    /// turn 1's calls. Same class as the positional guess in leg 2: a stale
    /// name is a confident lie.
    #[test]
    fn a_user_turn_clears_the_pending_calls() {
        let rows = flatten_messages(&[
            assistant_with(vec![call("c1", "read_file")]),
            zeus_core::Message::user("next question"),
            tool_row("c1"),
        ]);

        assert_eq!(
            rows[2].tool_name, None,
            "a call from BEFORE the operator's new question must not name a \
             row after it"
        );
    }
}
