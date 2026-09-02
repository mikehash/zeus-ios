import Foundation

/// One frame of an agent turn.
///
/// ## Why this is not `String`
///
/// The transport's element type was `String` until this commit, and the engine
/// folded every element into the trailing agent message with a single `+=`.
/// That is correct for prose and WRONG for everything else: the gateway emits
/// seven distinct in-band frames, and four of them are telemetry about what the
/// agent is *doing*, not words it is *saying*. Folding those into the transcript
/// renders a tool invocation as agent speech.
///
/// The flattening site was one `+=` (`SessionEngine.accumulate`). One site is
/// cheap to change and impossible to notice — which is why the type has to
/// carry the distinction rather than a comment asking the next editor to.
///
/// ## Provenance — SEVEN names, counted from the corpus
///
/// Census over `~/Zeus/crates/zeus-api/src/handlers/chat_handlers.rs` (whole
/// file, not the handler body), confirmed independently by Zeus100 at main
/// `b6c2058c3`:
///
///     thinking 4 · error 2 · iter 2 · tool_end 2 · tool_start 2 · token 1 · done 1
///     POS ctl `json!` = 25 · NEG ctl `zzznope` = 0
///
/// The handler's own doc comment at `:425-426` lists FIVE — it omits `iter`
/// AND `error`. A decoder written from that prose drops a progress frame and
/// renders a real agent failure as an unknown frame. Both seats published
/// "six" three times from a reading of that prose; the corpus says seven.
/// **A number that survives being repeated is not a number that was measured.**
///
/// ## The names ride INSIDE the payload
///
/// `.event(` = 0 sites against `.data(` = 17 at the same ref. The SSE
/// event-name field is never set, so every frame arrives as an undifferentiated
/// `message` and the decoder must parse the body to tell a token from a
/// failure. That is a fact about the decoder (commit ②), recorded here because
/// it is the reason this enum exists rather than a `String` keyed on `event:`.
///
/// Being an enum with no `default` at its consumers means an eighth wire name
/// cannot be added without every `switch` failing to compile.
enum SessionFrame: Equatable, Sendable {

    /// `token` — a delta of the agent's reply. The ONLY arm that is prose, and
    /// the only one the transcript accumulates.
    case token(String)

    /// `thinking` — reasoning trace. Prose, but not *answer* prose: it belongs
    /// to the agent's visible state, not to the transcript body.
    case thinking(String)

    /// `tool_start` — the agent invoked a tool.
    case toolStart(name: String)

    /// `tool_end` — the invocation returned. `ok` distinguishes a tool that
    /// answered from one that failed; collapsing them would make a failed
    /// tool call indistinguishable from a successful one in the operator's
    /// view, which is the entire reason to surface telemetry at all.
    case toolEnd(name: String, ok: Bool)

    /// `iter` — agent loop iteration counter. Progress, not content.
    case iteration(Int)

    /// `done` — the turn completed normally. Terminal.
    case done

    /// `error` — the AGENT failed, in band, mid-turn. Distinct from a thrown
    /// transport error: the socket is healthy and the server is telling us the
    /// turn went wrong. Mapping this onto a transport throw would send the
    /// operator to check the network for a model failure.
    case failure(String)

    /// True for the arms that carry agent-visible *speech*. Used at exactly one
    /// site (the fold) so the transcript's contents are decided by the type
    /// rather than by the reader of `accumulate`.
    var transcriptText: String? {
        switch self {
        case let .token(text):
            return text
        case .thinking, .toolStart, .toolEnd, .iteration, .done, .failure:
            return nil
        }
    }
}

/// A telemetry record — one non-prose frame, in arrival order.
///
/// Kept OUT of `[Message]` deliberately. The transcript is what was said; this
/// is what was done. A view can render them interleaved, but the model must not
/// conflate them, because a `+=` cannot be un-done once the text has merged.
struct SessionActivity: Equatable, Identifiable, Sendable {
    let id: UUID
    let frame: SessionFrame

    init(_ frame: SessionFrame, id: UUID = UUID()) {
        self.frame = frame
        self.id = id
    }

    /// Operator-facing one-liner. Exhaustive with no `default`.
    var label: String {
        switch frame {
        case let .token(text):        return text
        case let .thinking(text):     return text
        case let .toolStart(name):    return "→ \(name)"
        case let .toolEnd(name, ok):  return ok ? "✓ \(name)" : "✗ \(name)"
        case let .iteration(n):       return "iteration \(n)"
        case .done:                   return "done"
        case let .failure(reason):    return "agent error: \(reason)"
        }
    }
}
