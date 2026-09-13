import Foundation

/// The NON-PROSE seam — everything the app asks a backend that is not a turn.
///
/// ── Why a second protocol and not a second transport ───────────────────
///
/// `SessionTransport` already has four conformers and `HTTPTransport` is
/// already live at `Session.swift:174`, so prose ALREADY works against a
/// remote gateway. The parity gap is not the transport: it is that
/// `SessionTransport` is the ONLY seam. Five production surfaces hold a
/// `ZeusCoreProtocol` directly —
///
/// ```
/// ProviderArming.swift:40,110,167   NodesView.swift:125   HistoryView.swift:24
/// ```
///
/// — and every one of them is a feature that dies or silently degrades when
/// the operator is on a remote gateway, because the handle is either `nil` or
/// a LOCAL core that knows nothing about the remote node. A third transport
/// would have added a conformer beside a working second one and left all five
/// of those surfaces exactly as broken as they are today.
///
/// This protocol is the seam for the other kind of traffic: sessions, replay,
/// memory, models, arm-state. Two conformers are planned — `EmbeddedCapabilities`
/// (S2, here, wrapping `ZeusCoreProtocol`) and `GatewayCapabilities` (S3+, REST)
/// — resolved from the same `GatewayConfig` that already resolves the transport.
/// One seam per KIND of traffic.
///
/// ── What S2 is, and what it deliberately is not ────────────────────────
///
/// S2 is a PURE REFACTOR. The embedded conformer forwards every method to the
/// core unchanged, including the thrown error, and the five views take
/// `SessionCapabilities?` where they took `ZeusCoreProtocol?`. No behaviour
/// changes, no endpoint is added, no gateway conformer exists yet. The leg is
/// that the suite that passed before passes after, which is a weak instrument
/// on its own — so the surface census below is the stronger half.
///
/// ── Sendable, and why it is `AnyObject`-free ───────────────────────────
///
/// `ZeusCoreProtocol` is `AnyObject` because UniFFI emits a class. This one is
/// not: `GatewayCapabilities` will be a value type over `URLSession`, and
/// pinning the seam to reference types now would force that. `Sendable` for
/// the reason `LinkProbe:172` and `NotificationAuthority:156` are — conformers
/// are read from detached contexts (`HistoryView.open`, the picker's
/// `Task.detached`), and the compiler is the only thing that keeps that true.
///
/// ── Blocking, stated because the two conformers differ ─────────────────
///
/// The embedded conformer's methods BLOCK: they are FFI calls into a runtime
/// that owns its own executor, and `EmbeddedTransport:60-68` is where that is
/// discharged for prose. The gateway conformer's will not block; it will
/// suspend. The protocol is deliberately synchronous-and-throwing for S2
/// because making it `async` in the same commit would change every call site's
/// concurrency shape AND swap the implementation — two edits wearing one
/// commit, and a red would not say which half caused it. S3 carries the
/// `async` migration on its own.
protocol SessionCapabilities: Sendable {

    /// Whether THIS backend can send — the `Option` `send` reads on the
    /// embedded side, not the record the operator wrote.
    ///
    /// Carries `ProviderArming`'s exact subject, because the distinction that
    /// protocol was created to hold is the same one here: a string on disk and
    /// an armed backend are different facts, and the UI once showed READY on
    /// the first while sending on the second.
    ///
    /// ASYNC THROWS: the gateway conformer would have to block a URLSession
    /// call behind a semaphore to satisfy a synchronous form, and that
    /// deadlocks the cooperative pool. The knock-on is the point — `resolve`
    /// can no longer call it, so the record cannot promote itself to READY.
    func hasProvider() async throws -> Bool

    /// Number of files in the memory index. `nil` is NOT the empty index.
    ///
    /// `NodesView.mnemosyneValue:206` folds absence to `NO CORE` and zero to
    /// `INDEX EMPTY` and the whole subject of that row is that the two must
    /// stay distinguishable — so this returns `UInt32?` rather than defaulting.
    func indexSize() -> UInt32?

    /// The provider's catalogue, or a throw naming why it could not be read.
    ///
    /// THREE OUTCOMES KEPT DISTINCT, as the bridge's own doc requires: an
    /// unknown prefix throws naming the id, a live arm with no rows returns
    /// `[]`, and a transport failure or an unlisted prefix throws carrying the
    /// crate's sentence. A conformer that collapsed the last two would put the
    /// picker back in the state `65998af` fixed.
    func listModels(id: String, key: String, baseURL: String?) throws -> [String]

    /// The session list, in whatever order the backend produced it.
    ///
    /// ── Why THESE TWO are `async` and the other six are not ──────────────
    ///
    /// A `URLSession` conformer cannot satisfy a synchronous signature without
    /// a semaphore, and a semaphore on the cooperative pool deadlocks — that is
    /// a shape, not a taste. So the methods the gateway conformer implements
    /// must be `async`. Only these two are, and only because their ONLY
    /// production callers are already inside `Task.detached`
    /// (`HistoryView:177`, `:190`), which makes `await` free at both sites.
    ///
    /// The other six are read from `var body` and from `RootView.init`, where
    /// `await` is not available and the migration is a CACHING change, not a
    /// signature change — a stored reading plus a refresh task plus a third
    /// state so a cached value cannot render READY. That is S3b, with its own
    /// staleness legs, because a red in a commit carrying both could not say
    /// whether the transport or the caching broke it.
    ///
    /// Returns `[SessionRow]`, not the bridge's `[SessionInfo]`: the sort key
    /// is a fact the gateway does not have, and `SessionInfo.updatedAtRfc3339`
    /// is a generated non-Optional `String` with no `nil` to return. See
    /// `SessionRow`.
    func sessions() async throws -> [SessionRow]

    /// One session's transcript.
    ///
    /// `TurnMessage.toolName` is populated by the `call_id → id` join added in
    /// `4244aea`; a conformer that leaves it `nil` regresses replay to `[TOOL]`.
    /// The embedded path does that join in Rust; the gateway path must do the
    /// same join in its DECODER, because `TurnMessage` has no field that can
    /// carry a call id and therefore no way to do it afterwards. Two
    /// implementations of one join is the stated cost of remote replay.
    func messages(sessionID: String) async throws -> [TurnMessage]

    /// Write a fact to memory.
    func remember(fact: String) throws

    /// Query the memory index.
    ///
    /// Returns `[]` for a query that ran and found nothing. A conformer that
    /// cannot run the query at all must THROW — `Recall.findSummary:478` reads
    /// an empty array as "asked and got nothing", which is a lie if nobody
    /// asked.
    func search(query: String) -> [SearchHit]

    /// Arm the backend with a provider.
    func setProvider(id: String, model: String, key: String, baseURL: String?) throws
}

/// The embedded conformer: the one in-process core the app links.
///
/// Every method forwards unchanged, INCLUDING the thrown error. The bridge's
/// errors name their cause (`NoWorkspace`, an IO path, the provider's own
/// refusal sentence) and `RootView.remember:556` renders `"\(error)"`
/// verbatim, so wrapping them in a local error type here would discard the one
/// string that says why — the defect that comment names.
///
/// A `struct` over a `let`, so `Sendable` is structural: `ZeusCore` is a
/// UniFFI class and therefore a reference, which is why this is
/// `@unchecked`-free only because the protocol requires no mutable state.
struct EmbeddedCapabilities: SessionCapabilities, @unchecked Sendable {

    /// The bridge handle. Non-optional: absence is represented by a `nil`
    /// `SessionCapabilities?` at the call site, not by a conformer that
    /// answers for a core it does not have. A conformer wrapping `nil` would
    /// have to invent an answer for every method, and `indexSize` is the proof
    /// that inventing one is wrong.
    let core: ZeusCoreProtocol

    func hasProvider() async throws -> Bool { core.hasProvider() }

    /// Non-optional on the bridge, optional here. The widening is deliberate:
    /// the gateway conformer CAN fail to read a size (`/v1/memory/files` can
    /// 404 or refuse), and a protocol that could not express that would force
    /// it to return a fabricated zero into the row that exists to distinguish
    /// zero from unknown.
    func indexSize() -> UInt32? { core.indexSize() }

    func listModels(id: String, key: String, baseURL: String?) throws -> [String] {
        try core.listModels(id: id, key: key, baseUrl: baseURL)
    }

    /// `async` by signature, synchronous in fact: the bridge call reads a
    /// directory and returns. No `Task` is introduced here — the callers are
    /// already off the main thread and wrapping this in one would add a hop
    /// whose only purpose is to look like the gateway conformer.
    func sessions() async throws -> [SessionRow] {
        try core.sessions().map(SessionRow.init)
    }

    func messages(sessionID: String) async throws -> [TurnMessage] {
        try core.messages(sessionId: sessionID)
    }

    func remember(fact: String) throws { try core.remember(fact: fact) }

    func search(query: String) -> [SearchHit] { core.search(query: query) }

    func setProvider(id: String, model: String, key: String, baseURL: String?) throws {
        try core.setProvider(id: id, model: model, key: key, baseUrl: baseURL)
    }
}

extension EmbeddedCapabilities {

    /// The process's one core as a capability handle, or `nil` if the bridge
    /// failed to initialise.
    ///
    /// The single place `EmbeddedCore.shared` becomes a `SessionCapabilities`.
    /// Views must not call this — they receive the handle from `RootView`, for
    /// the reason `NodesView:118` gives: a handle built in a view would be a
    /// SECOND core over the same workspace directory.
    static func shared() -> EmbeddedCapabilities? {
        guard let core = try? EmbeddedCore.shared.get() else { return nil }
        return EmbeddedCapabilities(core: core)
    }
}

// MARK: - the resolver

/// Route a config to the capability handle that can serve it.
///
/// The analogue of `makeTransport` (`Session.swift:164`) for the NON-prose
/// seam, and it exists because that analogue was MISSING: at `2473e3b`,
/// `GatewayCapabilities` had ZERO production construction sites. It decoded,
/// it joined, it was covered by ten legs, and nothing could reach it. The
/// first-order gate — does the type exist and conform — passed; the
/// second-order gate — is it constructible from a production site — had never
/// been asked. That gap is what this function closes.
///
/// ── Why this returns Optional and `makeTransport` does not ────────────────
///
/// `makeTransport` can always produce SOMETHING: `UnconfiguredTransport` and
/// `MisconfiguredTransport` are conformers that carry a sentence instead of a
/// wire. This seam has no such conformer, and deliberately: every caller
/// already handles `nil` as `NO CORE`, because `EmbeddedCapabilities.shared()`
/// has always been Optional. Inventing a `MisconfiguredCapabilities` that
/// answers `sessions()` with `[]` would render "we could not ask" as "there
/// are no sessions" — the same class the `""`-under-`updatedAtRfc3339`
/// sentinel was rejected for.
///
/// ── Why only `.resolved` goes remote ──────────────────────────────────────
///
/// The switch is exhaustive with no `default`, same discipline as
/// `makeTransport`: a fifth `GatewayConfig` case cannot be added without this
/// failing to compile.
///
/// `.local` is the embedded core by definition. `.absent` and `.malformed`
/// have no endpoint to talk to — there is no URL, so there is nothing a
/// gateway conformer could be constructed AROUND — and they fall back to the
/// embedded core, which is exactly what those states meant before this
/// function existed.
///
/// ── What this does NOT do ─────────────────────────────────────────────────
///
/// It does not probe. Same note `makeTransport` carries: reachability is a
/// property of a request, not of a config, and a probe here would put a
/// network call on the app's launch path.
///
/// And it is wired at ONE of the five `EmbeddedCapabilities.shared()` sites —
/// `RootView:342`, the history sheet. See
/// `GatewayCapabilitiesTests.testTheConformerImplementsExactlyTwoMethods`
/// for why the other four must not move yet.
func makeCapabilities(for config: GatewayConfig,
                      credentials: CredentialProviding) -> SessionCapabilities? {
    switch config {
    case let .resolved(endpoint):
        return GatewayCapabilities(endpoint: endpoint, credentials: credentials)
    case .absent, .malformed, .local:
        return EmbeddedCapabilities.shared()
    }
}
