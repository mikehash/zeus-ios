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
    /// One agent turn. Each element is a *frame*, not a snapshot — the engine
    /// folds prose and records telemetry separately. Throwing terminates the
    /// turn; the accumulated text so far is kept, because a half-arrived answer
    /// is data and discarding it would be a second failure on top of the first.
    ///
    /// The element type was `String` until the frame cut. It is `SessionFrame`
    /// because four of the gateway's seven in-band names are NOT prose, and a
    /// prose channel can only render them as agent speech. See `SessionFrame`.
    func stream(prompt: String) -> AsyncThrowingStream<SessionFrame, Error>
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

    /// The gateway was configured and could not be reached at all — DNS,
    /// refused connection, TLS, timeout. Distinct from `.httpStatus`: nothing
    /// answered. Names the host because "the request failed" sends the reader
    /// to the wrong layer.
    case unreachable(host: String, detail: String)

    /// Something answered and refused. A 401 and a 502 are different operator
    /// actions (fix the token vs. fix the gateway), so the code is carried
    /// rather than folded into a sentence.
    case httpStatus(code: Int, body: String)

    /// Something answered with 2xx and the body was not a usable reply. This
    /// is the arm that catches a *successful* request that produced no answer
    /// — the case that would otherwise render as an empty agent bubble and
    /// read as a silent reply.
    case malformedResponse(detail: String)

    /// The AGENT failed, in band, mid-turn — an `error` frame on a healthy
    /// socket. Not a transport fault: the wire worked and the server is telling
    /// us the turn went wrong. Mapping this onto `.httpStatus` or `.unreachable`
    /// would send the operator to check the network for a model failure.
    case agentFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .unconfigured:
            return "NO TRANSPORT — this build has no gateway client. "
                 + "The session loop is live; nothing is listening."
        case let .misconfigured(detail):
            return "BAD GATEWAY CONFIG — \(detail). "
                 + "A gateway was supplied and could not be used."
        case let .agentFailed(reason):
            return "AGENT ERROR — \(reason). "
                 + "The wire is healthy; the turn itself failed."
        case let .unreachable(host, detail):
            return "GATEWAY UNREACHABLE — \(host): \(detail). "
                 + "Nothing answered; the request did not reach a server."
        case let .httpStatus(code, body):
            return "GATEWAY REFUSED — HTTP \(code): \(body). "
                 + "A server answered and rejected the request."
        case let .malformedResponse(detail):
            return "BAD GATEWAY RESPONSE — \(detail). "
                 + "The request succeeded and the body was not a usable reply."
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
    func stream(prompt: String) -> AsyncThrowingStream<SessionFrame, Error> {
        AsyncThrowingStream { $0.finish(throwing: TransportError.unconfigured) }
    }
}

/// A gateway was supplied and rejected. Fails with the config's own summary so
/// the transcript names the operand — `ZEUS_GATEWAY_URL="ftp://x" rejected:
/// scheme is not http or https` is actionable; "connection failed" is not.
struct MisconfiguredTransport: SessionTransport {
    let detail: String
    func stream(prompt: String) -> AsyncThrowingStream<SessionFrame, Error> {
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
/// `.resolved` returns an `HTTPTransport` — the real wire. It previously
/// returned a `MisconfiguredTransport` saying "no HTTP client in this build";
/// that sentence was true then and is false now, and it is deleted rather than
/// left standing, because a doc/code pair that drifts is only detectable while
/// one side still moves.
///
/// Note what `makeTransport` still does NOT do: it does not probe the endpoint.
/// A transport is *constructed* here, not connected — reachability is a
/// property of a request, not of a config, and pretending otherwise would put a
/// network call on the app's launch path.
func makeTransport(for config: GatewayConfig) -> SessionTransport {
    switch config {
    case .absent:
        return UnconfiguredTransport()
    case let .malformed(raw, reason):
        return MisconfiguredTransport(
            detail: "\(GatewayConfig.urlKey)=\"\(raw)\" rejected: \(reason.rawValue)")
    case let .resolved(endpoint):
        return HTTPTransport(endpoint: endpoint)
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

    /// Non-prose frames, in arrival order. Separate from `messages` by
    /// construction: the transcript is what was SAID, this is what was DONE.
    @Published private(set) var activity: [SessionActivity] = []

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
            for try await frame in transport.stream(prompt: prompt) {
                if Task.isCancelled { return }
                if state != .responding { state = .responding }
                absorb(frame, into: slot)               // invariant 1
            }
        } catch {
            fail(error, at: slot)
        }
    }

    // MARK: - Transcript mutation

    /// THE ONLY SITE THAT ROUTES A FRAME. See invariant 1.
    ///
    /// Routing is decided by `SessionFrame.transcriptText` — i.e. by the TYPE,
    /// not by a reader of this function. A frame that carries prose is folded;
    /// every other frame is recorded as activity and NEVER touches the
    /// transcript. Before the frame cut this body was a bare `+=`, which meant
    /// tool telemetry rendered as agent speech.
    ///
    /// `.failure` is folded into the transcript AS WELL as recorded, because an
    /// in-band agent error is the turn's outcome and a transcript that ends
    /// mid-sentence with the failure only in a side channel reads as the model
    /// choosing silence.
    private func absorb(_ frame: SessionFrame, into slot: Int) {
        activity.append(SessionActivity(frame))

        if let text = frame.transcriptText {
            accumulate(text, into: slot)
            return
        }
        if case let .done(text) = frame {
            replace(with: text, at: slot)
            return
        }
        if case let .failure(reason) = frame {
            fail(TransportError.agentFailed(reason: reason), at: slot)
        }
    }

    /// THE ONLY SITE THAT FOLDS PROSE INTO THE TRANSCRIPT.
    /// Bounds-checked because the slot is captured before the await: a caller
    /// that truncates the transcript mid-turn must not crash the app, and a
    /// silent no-op is the correct behaviour for a turn whose slot is gone.
    private func accumulate(_ text: String, into slot: Int) {
        guard messages.indices.contains(slot) else { return }
        messages[slot].text += text
    }

    /// THE ONLY SITE THAT REPLACES THE TRANSCRIPT. `done` carries the whole
    /// reply, so it is SET, never appended — one unbranched rule covering both
    /// producer paths:
    ///
    ///   streaming turn  — replace over the accumulated tokens. On the two
    ///                     emitters where the tokens and the return value are
    ///                     one pass apart (`agent_loop.rs:1344`, `:1448`) this
    ///                     is a NO-OP; on the third (`:2538`, whose reply is
    ///                     read from `response.content`, not folded) it is a
    ///                     REPAIR. Replacing cannot double, so it is safe
    ///                     whether or not they agree.
    ///   no-token turn   — replace over empty = the full reply. The
    ///                     empty-transcript bug cannot occur.
    ///
    /// The rule is NOT "discard `done.text` if any token arrived". That form
    /// is refuted by `agent_loop.rs:2543`, where a 90s idle BREAKS the token
    /// loop by design while the JoinHandle resolves with the complete text —
    /// tokens arrived, partial, and discarding the authority would keep the
    /// truncation. Replace is the only spelling correct on that path.
    ///
    /// TWO TIMEOUTS AT TWO LAYERS, and only one of them reaches this method:
    ///
    ///   `agent_loop.rs:2531`  90s, HARDCODED, per-CHUNK idle bound. Breaks the
    ///                         token loop; `:2553` still awaits the JoinHandle
    ///                         and `:2570` builds the reply from
    ///                         `response.content`, so the agent returns Ok.
    ///                         That reaches `gateway.rs:4688` — `Done(Ok(whole
    ///                         text))` with PARTIAL tokens on the wire. This is
    ///                         the REPAIR case, and it arrives HERE.
    ///   `gateway.rs:4690`     config `timeout_secs`, WHOLE-HANDLER bound.
    ///                         Returns `Done(Err(...))`, which
    ///                         `chat_handlers.rs:543` renders as `event:error`
    ///                         with NO text key. That arrives at `fail`, never
    ///                         here — the accumulated tokens are the sole
    ///                         carrier of the partial reply on that wire, so
    ///                         replacing would delete what the user watched
    ///                         arrive.
    ///
    /// The branch is on the Result the wire already carries, NOT on "did tokens
    /// arrive" — that form keeps the truncation on the `:2543` path.
    ///
    /// An empty `text` is still a replacement, deliberately: a server that
    /// returns an empty reply is reporting an empty reply.
    private func replace(with text: String, at slot: Int) {
        guard messages.indices.contains(slot) else { return }
        messages[slot].text = text
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
