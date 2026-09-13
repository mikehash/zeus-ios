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
    static func listSummary(sessionCount: Int?, serverOrder: Bool = false) -> String {
        guard let n = sessionCount else { return "NO CORE" }
        if n == 0 { return "NO SESSIONS YET" }
        let count = n == 1 ? "1 SESSION" : "\(n) SESSIONS"
        // `Theme.joined`, not an interpolated `·`: the separator is a layout
        // decision (it is the thing that strands at a line end on a 390pt
        // frame), and `check_separator_debt.sh` pins every hand-rolled site
        // precisely so a new one cannot be added without this choice being
        // made deliberately. It was made here.
        return serverOrder ? Theme.joined([count, "SERVER ORDER"]) : count
    }

    /// Whether this list is in the order the BACKEND sent it rather than an
    /// order this screen computed.
    ///
    /// True only when there is something to order and NOTHING can rank it —
    /// which is precisely the gateway's shape, where every `sortKey` is `nil`
    /// because `GET /v1/sessions` emits no `updated`. A mixed list is NOT
    /// server order: the rankable rows really are sorted newest-first above
    /// the sinks, so claiming server order there would be a false statement
    /// about rows the screen did order.
    ///
    /// An empty list is not server order either — there is no order to make a
    /// claim about, and `NO SESSIONS YET` already says the only true thing.
    static func isServerOrder(_ rows: [SessionRow]) -> Bool {
        !rows.isEmpty && rows.allSatisfy { $0.sortKey == nil }
    }

    /// Newest first, and INPUT ORDER for everything the key cannot rank.
    ///
    /// The core's `Session::list` yields `(id, updated_at)` and its doc says
    /// newest first — this re-sorts anyway, and the redundancy is deliberate:
    /// the order is a PROPERTY OF THIS SCREEN, and a core that changes its
    /// mind about ordering must not silently reorder the operator's history.
    ///
    /// ── Why the id tiebreak had to go, measured at `db19e4f0` ─────────────
    ///
    /// The arm this replaces was `case (nil, nil): return a.id < b.id` — a
    /// LEXICAL SORT OVER IDS, which is verbatim the costume defect the note
    /// below names: an ordering by NAME wearing the costume of an ordering by
    /// time. It was harmless while it fired for a stray unparseable row among
    /// parseable ones. The gateway conformer returns `nil` for EVERY row
    /// (`GET /v1/sessions` emits `created` and no `updated`, so there is no
    /// honest key to send), and an arm that is a rare tiebreak becomes the
    /// PRIMARY SORT the moment every input reaches it. A fallback's behaviour
    /// is a function of how many inputs reach it.
    ///
    /// Nor does declining to order preserve input order: `sorted(by:)` is
    /// documented as NOT guaranteed stable, so a comparator returning `false`
    /// for every pair still licenses any permutation. Input order has to be
    /// SAID, which is what the decorated index says.
    ///
    /// ── Why the index is in the (nil, nil) arm only ───────────────────────
    ///
    /// "Any pair without two parsed keys orders by index" is NOT a strict weak
    /// ordering and Swift's `sorted(by:)` has undefined behaviour when given
    /// one. Measured counterexample — A(idx 0, old), B(idx 1, nil),
    /// C(idx 2, new): A<B by index, B<C by index, C<A by date. A cycle. The
    /// sink arms must stay: an unparsed row loses to every parsed row, and the
    /// index decides only between two unparsed rows.
    ///
    /// ── Why the parameter is a `SessionRow` and not a `SessionInfo` ───────
    ///
    /// The key is now `String?` and the `nil` arrives from a conformer that
    /// HAS NO KEY TO SEND, not from a key that failed to parse. Those two
    /// facts reach the same arm and that is correct — neither can be ranked —
    /// but only one of them can be expressed by a UniFFI `String`. See
    /// `SessionRow.sortKey`.
    static func newestFirst(_ sessions: [SessionRow]) -> [SessionRow] {
        sessions.enumerated()
            .map { (index: $0.offset, key: $0.element.sortKey.flatMap(parse), row: $0.element) }
            .sorted { a, b in
                switch (a.key, b.key) {
                case let (x?, y?): return x > y
                // An unparseable timestamp sinks rather than sorting as
                // `.distantPast`-equal-to-everything: it keeps a stable place
                // instead of jostling with its neighbours on every render.
                case (nil, _?):    return false
                case (_?, nil):    return true
                // Both unrankable: the order they ARRIVED in. Server order on
                // the gateway path, file order on the embedded path — never a
                // fabricated one.
                case (nil, nil):   return a.index < b.index
                }
            }
            .map(\.row)
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
    /// ── `nil`: the trailing slot renders EMPTY ───────────────────────────
    ///
    /// A backend that cannot say when a session was last written gets no
    /// per-row string here. Not `UNKNOWN` — that reads as a parse failure of a
    /// key that was never sent, and it would repeat on every row a fact that is
    /// true of the whole LIST. The list header carries `SERVER ORDER` once, at
    /// the level where the fact is true.
    static func ago(_ rfc3339: String?, now: Date = Date()) -> String {
        guard let rfc3339 else { return "" }
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
