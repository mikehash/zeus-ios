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
    func hasProvider() -> Bool

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

    /// The session list, most recent first.
    func sessions() throws -> [SessionInfo]

    /// One session's transcript.
    ///
    /// `TurnMessage.toolName` is populated by the `call_id → id` join added in
    /// `4244aea`; a conformer that leaves it `nil` regresses replay to `[TOOL]`.
    func messages(sessionID: String) throws -> [TurnMessage]

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

    func hasProvider() -> Bool { core.hasProvider() }

    /// Non-optional on the bridge, optional here. The widening is deliberate:
    /// the gateway conformer CAN fail to read a size (`/v1/memory/files` can
    /// 404 or refuse), and a protocol that could not express that would force
    /// it to return a fabricated zero into the row that exists to distinguish
    /// zero from unknown.
    func indexSize() -> UInt32? { core.indexSize() }

    func listModels(id: String, key: String, baseURL: String?) throws -> [String] {
        try core.listModels(id: id, key: key, baseUrl: baseURL)
    }

    func sessions() throws -> [SessionInfo] { try core.sessions() }

    func messages(sessionID: String) throws -> [TurnMessage] {
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
