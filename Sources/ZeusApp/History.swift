import Foundation

/// C — the last dark core export pair: `sessions()` and `messages(sessionId:)`.
///
/// ── Why this file is pure, again ────────────────────────────────────────
///
/// Same measured reason as `Recall`: a SwiftUI `var body` has no importable
/// surface from the test target, so every decision this feature makes — what
/// a session row says, how a timestamp is rendered, which roles reach the
/// screen and how a tool row is labelled — lives here as a function of its
/// inputs. The view calls these and renders the answer.
///
/// ── What the core actually persists, walked at `7d592e7` ───────────────
///
/// `send` now threads the session id it used to discard (`lib.rs:268`,
/// `let _ = session_id`) into `Session::resume_or_create(sessions_dir, id)`,
/// and the loop's own `session.add` calls (`agent_loop:1657` user,
/// `:2571` assistant) write both halves of the turn to
/// `sessions_dir/{id}.jsonl`. So a session file exists because a TURN RAN —
/// there is no "create session" affordance and there should not be one: an
/// empty session is a row that promises a conversation nobody had.
enum History {

    // MARK: - the session list

    /// What the list area says, over (has the core answered, how many).
    ///
    /// THREE READINGS, NOT TWO, and it is the `findSummary` discrimination one
    /// subsystem over. `nil` is "no core" — the handle failed to initialise.
    /// `[]` is a core that answered and has nothing, which on this surface is
    /// the ordinary state of a fresh install, not a fault. Folding them gives
    /// a broken core the same screen as a new phone.
    static func listSummary(sessionCount: Int?) -> String {
        guard let n = sessionCount else { return "NO CORE" }
        if n == 0 { return "NO SESSIONS YET" }
        return n == 1 ? "1 SESSION" : "\(n) SESSIONS"
    }

    /// Newest first.
    ///
    /// The core's `Session::list` yields `(id, updated_at)` and its doc says
    /// newest first — this re-sorts anyway, and the redundancy is deliberate:
    /// the order is a PROPERTY OF THIS SCREEN, and a core that changes its
    /// mind about ordering must not silently reorder the operator's history.
    /// The sort key is the parsed date; ids sort lexically and a lexical sort
    /// over ids is an ordering by NAME wearing the costume of an ordering by
    /// time.
    static func newestFirst(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.sorted { a, b in
            let da = parse(a.updatedAtRfc3339)
            let db = parse(b.updatedAtRfc3339)
            switch (da, db) {
            case let (x?, y?): return x > y
            // An unparseable timestamp sinks rather than sorting as
            // `.distantPast`-equal-to-everything: it keeps a stable place
            // instead of jostling with its neighbours on every render.
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return a.id < b.id
            }
        }
    }

    /// RFC3339 with fractional seconds tolerated.
    ///
    /// The core writes `chrono`'s `to_rfc3339()`, which emits nanoseconds
    /// (`...T04:11:07.123456789+00:00`). `ISO8601DateFormatter` with default
    /// options REFUSES that string — returns nil — so every row would have
    /// sorted as unparseable and the "newest first" claim would have been
    /// decided by the id tiebreak. Measured, not assumed: the fractional
    /// option is the difference between a sorted list and an alphabetical one.
    static func parse(_ rfc3339: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: rfc3339) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: rfc3339)
    }

    /// The row's trailing slot: when this session was last written.
    ///
    /// Relative ("4 MIN AGO"), because the absolute instant is not the
    /// question the operator is asking of a history list. Unparseable returns
    /// the raw string rather than a fabricated "JUST NOW" — the one thing
    /// worse than an ugly timestamp is a confident wrong one.
    static func ago(_ rfc3339: String, now: Date = Date()) -> String {
        guard let then = parse(rfc3339) else { return rfc3339 }
        let s = Int(now.timeIntervalSince(then))
        if s < 0    { return "JUST NOW" }   // clock skew, not the future
        if s < 60   { return "JUST NOW" }
        if s < 3600 { return "\(s / 60) MIN AGO" }
        if s < 86_400 { return "\(s / 3600) HR AGO" }
        return "\(s / 86_400) DAY AGO"
    }

    /// The row's leading slot: the session's own id, shortened.
    ///
    /// `resume_or_create` files under the id the app passed, which is the
    /// gateway-named label the header already prints — so this is a MIRROR of
    /// a value the operator has seen, never a new name for the same thing.
    static func rowTitle(for id: String) -> String {
        let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "UNTITLED" : t.uppercased()
    }

    // MARK: - the transcript

    /// One rendered transcript row.
    struct Row: Equatable, Identifiable {
        enum Kind: String, Equatable { case user, assistant, tool }
        var id: Int
        var kind: Kind
        var text: String
    }

    /// The core's `[TurnMessage]` as rows this screen can draw.
    ///
    /// ── The tool row is the whole difficulty, and it is a SUBSTRATE fact ──
    ///
    /// `agent_loop` persists a tool turn as `Message { role: Tool, content:
    /// String::new(), tool_results: vec![...] }` (`:2866`, `:3076`) — the
    /// CONTENT IS EMPTY and the payload lives in `tool_results`, which
    /// `TurnMessage` does not carry (the bridge's record is role + content +
    /// timestamp, `lib.rs:415`). So a persisted tool row read back through
    /// `messages(id)` has NOTHING TO PRINT.
    ///
    /// Rendered verbatim it is a blank bubble: a row with a border and no
    /// text, which reads as a rendering bug. Dropped, the transcript claims a
    /// turn went straight from question to answer with no tool call — the
    /// screen would be lying about the loop that is the entire point of C2.
    ///
    /// So a tool row renders the `[NAME]` marker shape the live pump already
    /// emits (`lib.rs:694`, `format!("\n[{}]\n", name.to_uppercase())`).
    ///
    /// The name now ARRIVES: `TurnMessage.toolName` is the bridge's join of
    /// `ToolResult.call_id` against the preceding assistant turn's
    /// `ToolCall.id` — the persisted row itself has no name field, so this is
    /// recovered, not read. It is `nil` whenever the join found no match, and
    /// the fallback is the generic `[TOOL]`, NEVER a guess: a wrong tool name
    /// reads as fact, while a generic marker is visibly generic.
    ///
    /// Precedence is name-then-content. A tool row's content is empty by
    /// construction, so the content branch survives only for rows some other
    /// writer may have filled — it must not shadow the joined name.
    ///
    /// System messages never arrive — the bridge already filters them
    /// (`lib.rs:409`, "the persona, not the conversation") — so this maps the
    /// three roles it can receive and DROPS an unknown fourth rather than
    /// inventing a kind for it.
    static func rows(from messages: [TurnMessage]) -> [Row] {
        var out: [Row] = []
        for m in messages {
            let text = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            switch m.role {
            case "user":
                guard !text.isEmpty else { continue }
                out.append(Row(id: out.count, kind: .user, text: text))
            case "assistant":
                guard !text.isEmpty else { continue }
                out.append(Row(id: out.count, kind: .assistant, text: text))
            case "tool":
                // NOT gated on emptiness — empty is the NORMAL shape here,
                // per the walk above. Gating it would delete every tool row
                // the loop has ever written.
                let marker: String
                if let name = m.toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty {
                    marker = "[\(name.uppercased())]"
                } else if !text.isEmpty {
                    marker = "[\(text.uppercased())]"
                } else {
                    marker = "[TOOL]"
                }
                out.append(Row(id: out.count, kind: .tool, text: marker))
            default:
                continue
            }
        }
        return out
    }

    /// What the transcript area says when it has no rows to draw.
    static func transcriptSummary(rowCount: Int?) -> String {
        guard let n = rowCount else { return "NO CORE" }
        return n == 0 ? "THIS SESSION HAS NO TURNS" : "\(n) TURNS"
    }
}
