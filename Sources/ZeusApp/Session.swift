import Foundation

// MARK: - Transport

/// The wire the session loop talks to.
///
/// The prototype fakes a reply on a timer (`sendChat`, ZeusApp.jsx:455-467 at
/// `817b19d3d`): it appends an empty agent message, then walks a hardcoded
/// string word-by-word on `setTimeout`. That is a *presentation* of streaming
/// with no sender behind it.
///
/// This protocol is the seam where a real sender goes. Everything above it —
/// turn lifecycle, accumulation, cancellation, error surfacing — is real and
/// runs identically whether the stream comes from a gateway or from a stub.
/// Nothing below it exists in this tree yet, and `UnconfiguredTransport` says
/// so out loud rather than answering.
protocol SessionTransport: Sendable {
    /// One agent turn. Each element is a *delta*, not a snapshot — the engine
    /// accumulates. Throwing terminates the turn; the accumulated text so far
    /// is kept, because a half-arrived answer is data and discarding it would
    /// be a second failure on top of the first.
    func stream(prompt: String) -> AsyncThrowingStream<String, Error>
}

enum TransportError: LocalizedError, Equatable {
    /// No gateway is configured in this build. Not a network failure — the
    /// absence of a wire, which is a different fact and deserves different
    /// words in the transcript.
    case unconfigured

    /// A gateway WAS supplied and could not be used. Distinct from
    /// `.unconfigured` on purpose: "you gave me nothing" and "you gave me
    /// something I can't use" are different operator actions, and collapsing
    /// them sends the reader to check the wrong thing. Carries the config's own
    /// summary so the transcript quotes the operand instead of describing it.
    case misconfigured(detail: String)

    var errorDescription: String? {
        switch self {
        case .unconfigured:
            return "NO TRANSPORT — this build has no gateway client. "
                 + "The session loop is live; nothing is listening."
        case let .misconfigured(detail):
            return "BAD GATEWAY CONFIG — \(detail). "
                 + "A gateway was supplied and could not be used."
        }
    }
}

/// The default transport, and the only one in this tree.
///
/// It fails immediately with `.unconfigured`. That is the deliberate choice
/// carried forward from the M3-era `send`: **a stub that answers looks
/// identical to one that works.** A canned reply would make the transcript
/// indistinguishable from a wired build, and the first person to demo it
/// would believe the wire exists. Failing loudly is the honest signal, and
/// it exercises the engine's error path on every send — so the path that is
/// hardest to reach in a wired build is the one that runs by default here.
struct UnconfiguredTransport: SessionTransport {
    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: TransportError.unconfigured) }
    }
}

/// A gateway was supplied and rejected. Fails with the config's own summary so
/// the transcript names the operand — `ZEUS_GATEWAY_URL="ftp://x" rejected:
/// scheme is not http or https` is actionable; "connection failed" is not.
struct MisconfiguredTransport: SessionTransport {
    let detail: String
    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: TransportError.misconfigured(detail: detail)) }
    }
}

/// Selects the transport for a resolved config.
///
/// EXHAUSTIVE over `GatewayConfig` by `switch` with no `default`, so a fourth
/// config case cannot be added without this function failing to compile. A
/// `default` here would silently route a new case to the absent arm — the
/// compiler holds the mapping instead of a comment.
///
/// `.resolved` currently routes to `.misconfigured` with an explicit reason,
/// because **the HTTP client does not exist in this tree yet.** That is the
/// honest arm: a config that resolves but has no client behind it must not
/// report success, and it must not report `NO TRANSPORT` either — neither
/// sentence is true. It says the client is missing, and this line is the single
/// site the real client lands at.
func makeTransport(for config: GatewayConfig) -> SessionTransport {
    switch config {
    case .absent:
        return UnconfiguredTransport()
    case let .malformed(raw, reason):
        return MisconfiguredTransport(
            detail: "\(GatewayConfig.urlKey)=\"\(raw)\" rejected: \(reason.rawValue)")
    case let .resolved(endpoint):
        return MisconfiguredTransport(
            detail: "\(endpoint.url.absoluteString) resolved, but this build "
                  + "has no HTTP client (M5 in progress)")
    }
}

// MARK: - Engine

/// The session loop.
///
/// Owns the transcript and the agent state, and is the ONLY writer of either.
/// `RootView` reads and calls `send`; it cannot append a message or set a
/// state, because neither is exposed for writing. That is the same shape as
/// the console gating on `Commission` as *state* rather than navigation: the
/// invariant lives in what is reachable, not in what an editor remembers.
///
/// ## The three invariants, and why each is structural
///
/// 1. **One writer for the trailing agent turn.** `deltas` are folded into the
///    transcript at exactly one site (`accumulate`). A second append site
///    could interleave with an in-flight stream and produce two trailing
///    agent messages; there is no second site to interleave.
///
/// 2. **Every exit path returns to `.ambient` and clears `streaming`.** Not
///    written three times at three `return`s — written ONCE in a `defer`, so
///    a future `return`, `throw`, or cancellation added anywhere in the turn
///    body inherits the cleanup instead of needing to remember it. A caret
///    orphaned by an early return is invisible in every test that checks the
///    happy path.
///
/// 3. **At most one turn in flight.** `send` cancels the previous task before
///    starting the next. Two concurrent streams would both fold into "the
///    trailing agent message" and produce interleaved words — the classic
///    shape that only appears under fast typing and never under a demo.
@MainActor
final class SessionEngine: ObservableObject {

    @Published private(set) var messages: [Message]
    @Published private(set) var state: AgentState = .ambient

    private let transport: SessionTransport
    private var turn: Task<Void, Never>?

    /// Seeded from the prototype's initial transcript, :411-412.
    init(transport: SessionTransport = UnconfiguredTransport(),
         seed: [Message] = [
            Message(role: .agent,
                    text: "Operator link established. All systems nominal — "
                        + "Kitchen node quiet. Standing by.")
         ]) {
        self.transport = transport
        self.messages = seed
    }

    /// Begin a turn. Empty and whitespace-only prompts are refused here rather
    /// than at the button, so the refusal holds for every caller — the view's
    /// send/mic swap is presentation, not the guard.
    func send(_ raw: String) {
        let prompt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        turn?.cancel()                                  // invariant 3
        messages.append(Message(role: .user, text: prompt))
        turn = Task { [weak self] in await self?.run(prompt) }
    }

    /// Abandon the in-flight turn. Cleanup runs through the same `defer` as a
    /// natural completion, so cancel is not a separate teardown path.
    func cancelTurn() {
        turn?.cancel()
        turn = nil
    }

    private func run(_ prompt: String) async {
        state = .thinking

        let slot = messages.count
        messages.append(Message(role: .agent, text: "", streaming: true))

        // Invariant 2. Single site, runs on completion, throw, and cancel.
        defer {
            settle(slot)
            state = .ambient
        }

        do {
            for try await delta in transport.stream(prompt: prompt) {
                if Task.isCancelled { return }
                if state != .responding { state = .responding }
                accumulate(delta, into: slot)           // invariant 1
            }
        } catch {
            fail(error, at: slot)
        }
    }

    // MARK: - Transcript mutation

    /// THE ONLY SITE THAT FOLDS A DELTA INTO THE TRANSCRIPT. See invariant 1.
    /// Bounds-checked because the slot is captured before the await: a caller
    /// that truncates the transcript mid-turn must not crash the app, and a
    /// silent no-op is the correct behaviour for a turn whose slot is gone.
    private func accumulate(_ delta: String, into slot: Int) {
        guard messages.indices.contains(slot) else { return }
        messages[slot].text += delta
    }

    /// Terminal state for a failed turn. The accumulated text is KEPT and the
    /// error is appended beneath it — a half-arrived answer plus its failure
    /// is strictly more information than either alone.
    private func fail(_ error: Error, at slot: Int) {
        guard messages.indices.contains(slot) else { return }
        let reason = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        let existing = messages[slot].text
        messages[slot].text = existing.isEmpty ? reason : existing + "\n\n" + reason
    }

    /// Clears the caret. Called only from the `defer`, so there is no path on
    /// which a turn ends with `streaming == true`.
    private func settle(_ slot: Int) {
        guard messages.indices.contains(slot) else { return }
        messages[slot].streaming = false
    }
}
