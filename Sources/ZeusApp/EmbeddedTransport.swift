import Foundation

/// The session wire when the gateway runs ON THIS PHONE.
///
/// ## What this is
///
/// `HTTPTransport` speaks to a gateway somewhere else. `EmbeddedTransport`
/// speaks to `ZeusCore` — the UniFFI bridge over the Rust core, linked into
/// this binary as a static archive (`rust/zeus-core-bridge`, pinned to
/// `mikehash/Zeus@2a2168cd`). Same protocol, no network, no endpoint, no
/// reachability.
///
/// ## THE NARROWER WIRE — declared here, not discovered in a transcript
///
/// `SessionFrame` has seven arms because the *gateway* emits seven in-band
/// events. **This transport emits exactly one of them: `.token`.**
///
/// That is not a simplification, it is the shape of the bridge: `TokenSink`
/// (`zeus_core_bridge.swift:997`) has three methods — `onToken`, `onComplete`,
/// `onError` — and there is no agent loop behind `send` until zeus107's
/// `automation` feature gate lands on main. There are no tool invocations to
/// report, no iteration counter to count, and no thinking phase to show,
/// because nothing runs between the prompt and the provider.
///
/// So the transcript for a `.local` turn renders prose and NOTHING ELSE. No
/// placeholder "thinking…", no spinner standing in for a phase that does not
/// exist. A UI that meters an absent phase is the same defect as a stub that
/// answers: it is indistinguishable from the wired build, which is the one
/// thing the operator needs to be able to tell apart.
///
/// When the agent loop lands, this comment is the thing that must change, and
/// the frames it names are the ones that become available.
///
/// ## Push → pull
///
/// The bridge is push (`sink.onToken(...)`); `SessionTransport` is pull
/// (`AsyncThrowingStream`). The adapter is `StreamSink` below: it holds the
/// stream's continuation and forwards each callback to it. `onComplete` and
/// `onError` are TERMINAL and finish the stream — the sink is a one-turn
/// object, not a reusable listener.
///
/// `onComplete(fullText:)` is DISCARDED rather than yielded. The core sends
/// the accumulated text a second time at the end of the turn; yielding it as a
/// `.token` would double the reply, and yielding it as `.done` would be a
/// whole-turn authority the engine would fold on top of what it already has.
/// The tokens already arrived. Completion is a lifecycle fact, not content.
///
/// ## OFF-MAIN IS THIS TYPE'S OBLIGATION
///
/// `ZeusCore.send` is `rt.block_on` — it **blocks the calling thread for the
/// whole turn**, deliberately and documented at `rust/zeus-core-bridge/
/// src/lib.rs:186` (chosen over a detached spawn so the turn stays cancellable
/// and can report a panic). Called from `@MainActor`, it freezes the UI for
/// the length of a model response.
///
/// The Rust side correctly refuses to hide that. This type is where it is
/// discharged: `stream` dispatches onto `queue` — a private serial queue owned
/// by this transport — and NOTHING on `@MainActor` ever calls the bridge
/// directly. `SessionEngine` is `@MainActor`; it calls `stream`, which returns
/// immediately with an unstarted stream, and the block happens on `queue`.
///
/// This type is deliberately NOT `@MainActor` and deliberately `Sendable`. The
/// compile-time half of that claim is asserted in `EmbeddedTransportTests`.
struct EmbeddedTransport: SessionTransport {

    /// The bridge handle. Shared for the process — see `EmbeddedCore`.
    private let core: ZeusCoreProtocol

    /// The thread the core is allowed to block.
    ///
    /// SERIAL, not concurrent, and that is a decision rather than a default:
    /// the core is a single runtime and two turns racing into `block_on` from
    /// different threads would interleave inside one session's history. Serial
    /// makes "one turn at a time" a property of the queue instead of a rule
    /// the caller has to remember.
    private let queue: DispatchQueue

    /// The session id this transport reports turns under.
    private let sessionID: SessionIDBox

    init(core: ZeusCoreProtocol,
         sessionID: SessionIDBox,
         queue: DispatchQueue = EmbeddedCore.queue) {
        self.core = core
        self.sessionID = sessionID
        self.queue = queue
    }

    func stream(prompt: String) -> AsyncThrowingStream<SessionFrame, Error> {
        let core = self.core
        let queue = self.queue
        let id = resolvedSessionID()

        return AsyncThrowingStream { continuation in
            let sink = StreamSink(continuation: continuation)

            // The whole reason this type exists. `send` blocks; it blocks
            // HERE, on a queue nobody is drawing a UI from.
            queue.async {
                do {
                    try core.send(sessionId: id, text: prompt, sink: sink)
                } catch {
                    // A throw from `send` itself (BridgeError) — as opposed to
                    // an error delivered through `onError` — still has to
                    // terminate the stream, or the consumer awaits forever.
                    // Both paths are funnelled through the sink so the
                    // "finish exactly once" rule has ONE owner.
                    sink.onError(message: Self.describe(error))
                }
            }
        }
    }

    /// The id this turn is filed under in the core.
    ///
    /// `SessionIDBox.current` is `nil` until a reply NAMES a session — that is
    /// the HTTP shape, where the gateway assigns the id and the box records
    /// what came back. The embedded core has no such handshake: `send` takes
    /// an id as an *input*, so somebody has to choose one for the first turn.
    ///
    /// The transport chooses, and WRITES IT BACK through `set`, so turn two
    /// reuses turn one's id rather than starting a fresh history every message.
    /// Without the write-back each turn would be a new session in the core and
    /// the conversation would have no memory of itself — a defect that is
    /// invisible in a one-turn test.
    private func resolvedSessionID() -> String {
        if let existing = sessionID.current { return existing }
        let fresh = UUID().uuidString
        sessionID.set(fresh)
        // Re-read rather than returning `fresh`: `set` is the only writer and
        // it refuses empties, so the box is the authority on what was stored.
        return sessionID.current ?? fresh
    }

    /// Render a bridge error as the sentence a transcript will show.
    ///
    /// `BridgeError` is a generated enum with no `Error` conformance worth
    /// printing — `String(describing:)` on it yields `NoProvider`, which is a
    /// symbol rather than a sentence. Named arms get named text; anything else
    /// falls back to the raw description rather than to a friendly lie.
    static func describe(_ error: Error) -> String {
        guard let bridge = error as? BridgeError else {
            return String(describing: error)
        }
        switch bridge {
        case .NoProvider:
            // Reachable only if the surface let a send through while
            // `.local(.noProvider)` was the config — i.e. only if the disarm
            // in `GatewayConfig.disarmReason` was bypassed. It is a backstop,
            // not the primary path, and it says the same words so the two
            // cannot drift into two different explanations of one state.
            return GatewayConfig.noProviderMessage
        case let .Unsupported(message):
            // A typed refusal, not a failure: the core is saying "this
            // provider does not answer for me". The crate's own text is the
            // specific one (`list_models` names the provider), so it is shown
            // verbatim rather than replaced with a generic sentence that
            // would lose which provider refused.
            return message
        case let .Core(message):
            return message
        }
        // Deliberately no `default:`. `BridgeError` is GENERATED — it grew
        // `.Unsupported` in the same regen that produced this arm, and the
        // exhaustive switch is what surfaced it (build error, not a silent
        // absorb into a fallback string). A `default:` here would render the
        // next new arm as whatever the catch-all says, which is a wrong
        // sentence shown confidently. Keep the compile error.
    }
}

// MARK: - Push → pull adapter

/// Bridges `TokenSink`'s three callbacks onto one `AsyncThrowingStream`.
///
/// A class because `TokenSink` is `AnyObject` — UniFFI holds it across the FFI
/// boundary by handle. Its lifetime is one turn: Rust drops the handle when
/// `send` returns, which releases this object.
///
/// ## Finish exactly once
///
/// `onComplete` and `onError` are both terminal, and `EmbeddedTransport` also
/// routes a synchronous throw from `send` through `onError`. That is three
/// paths into one `finish`, and `AsyncThrowingStream.Continuation.finish` past
/// the first call is documented as a no-op — but relying on that would mean
/// the invariant lives in Apple's implementation notes. `finished` holds it
/// here, under the lock, so the second call is provably dropped rather than
/// tolerated.
private final class StreamSink: TokenSink, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<SessionFrame, Error>.Continuation
    private let lock = NSLock()
    private var finished = false

    init(continuation: AsyncThrowingStream<SessionFrame, Error>.Continuation) {
        self.continuation = continuation
    }

    func onToken(token: String) {
        lock.lock(); let done = finished; lock.unlock()
        guard !done else { return }
        continuation.yield(.token(token))
    }

    func onComplete(fullText: String) {
        // `fullText` is DISCARDED. See the type doc: the tokens already
        // arrived, and re-yielding the accumulation would double the reply.
        guard claimFinish() else { return }
        continuation.finish()
    }

    func onError(message: String) {
        guard claimFinish() else { return }
        continuation.finish(throwing: TransportError.embedded(detail: message))
    }

    /// Returns true exactly once, for the first caller.
    private func claimFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}

// MARK: - Process-lifetime bridge handle

/// The one `ZeusCore` this process owns.
///
/// ## Why a singleton, stated rather than assumed
///
/// `ZeusCore.init` owns a `tokio` runtime and scans the workspace to build the
/// file index. Both are process-scoped costs: a second core would be a second
/// runtime and a second scan, and `makeTransport` builds a transport PER TURN
/// (`Session.swift:193` — a factory, not an instance). A per-turn core would
/// re-scan the workspace on every message.
///
/// ## The failure is carried, not thrown away
///
/// `init` can fail. A `try!` here would crash the app on a workspace it cannot
/// create; a silent `nil` would make "core failed to start" indistinguishable
/// from "no core in this build" — the exact confusion `GatewayConfig` exists
/// to prevent. So the failure is stored and rendered: `makeTransport` returns
/// a `MisconfiguredTransport` naming it, and the transcript quotes the reason.
enum EmbeddedCore {

    /// The queue every embedded turn blocks on. See `EmbeddedTransport.queue`.
    static let queue = DispatchQueue(label: "com.zeus.embedded-core",
                                     qos: .userInitiated)

    /// Result of the one initialisation attempt, computed lazily on first use.
    ///
    /// `lazy` on a `static` is atomic in Swift (`swift_once`), so two turns
    /// racing to send cannot build two cores.
    static let shared: Result<ZeusCore, Error> = {
        do {
            // `ZeusCore.init` is a NAMED Rust constructor, so UniFFI emits it
            // as a static func with a backticked name — not a Swift
            // initialiser. `ZeusCore(workspaceDir:)` does not compile; this is
            // the generated surface, not a style choice.
            return .success(try ZeusCore.`init`(workspaceDir: workspaceDirectory()))
        } catch {
            return .failure(error)
        }
    }()

    /// Where the core keeps sessions and memory on the device.
    ///
    /// Application Support, not Documents: this is app-managed state the user
    /// never browses, and Documents is user-visible in the Files app when
    /// file sharing is on. Not Caches — the system may evict Caches under
    /// pressure, and evicting a session history mid-conversation would be a
    /// data loss that looks like a bug.
    static func workspaceDirectory() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("zeus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.path
    }
}
