import XCTest
@testable import Zeus

/// C — legs for the session list and the transcript.
///
/// Two-arm everywhere: the ruling's own words were "the two-arm empty/two-row
/// leg", because "the export returns nothing" and "the view ignores the
/// export" render identically under a one-arm test.
final class HistoryTests: XCTestCase {

    private func info(_ id: String, _ ts: String) -> SessionInfo {
        SessionInfo(id: id, updatedAtRfc3339: ts)
    }
    private func msg(_ role: String, _ content: String) -> TurnMessage {
        TurnMessage(role: role, content: content,
                    timestampRfc3339: "2026-09-11T04:00:00Z")
    }

    // MARK: - the list, both arms

    /// ARM 1 — empty is a reading, not an absence.
    /// ARM 2 — a populated core says how many.
    /// ARM 3 — `nil` is a THIRD state; folded into arm 1 a dead core reads
    ///         like a fresh install.
    func testTheListDistinguishesNoCoreFromNoSessions() {
        XCTAssertEqual(History.listSummary(sessionCount: 0), "NO SESSIONS YET")
        XCTAssertEqual(History.listSummary(sessionCount: 2), "2 SESSIONS")
        XCTAssertEqual(History.listSummary(sessionCount: 1), "1 SESSION")
        XCTAssertEqual(History.listSummary(sessionCount: nil), "NO CORE")
        // The vacuity assertion: the three states must not be one string.
        XCTAssertNotEqual(History.listSummary(sessionCount: nil),
                          History.listSummary(sessionCount: 0))
    }

    /// Newest first, and the leg that discriminates a TIME sort from a NAME
    /// sort: the alphabetically-first id is the newest, so a lexical sort
    /// yields the same order and passes a naive assertion. Here it must not.
    func testNewestFirstSortsByTimeNotByName() {
        let older = info("aaa-first-alphabetically", "2026-09-11T04:00:00Z")
        let newer = info("zzz-last-alphabetically",  "2026-09-11T06:00:00Z")
        let out = History.newestFirst([older, newer])
        XCTAssertEqual(out.map(\.id), [newer.id, older.id])
        // Vacuity: if the sort were lexical, `out` would equal the input.
        XCTAssertNotEqual(out.map(\.id), [older.id, newer.id])
    }

    /// The fractional-seconds arm. `chrono::to_rfc3339()` emits nanoseconds;
    /// a default `ISO8601DateFormatter` refuses that string, and every row
    /// would have fallen to the id tiebreak while LOOKING sorted.
    func testFractionalSecondsParse() {
        XCTAssertNotNil(History.parse("2026-09-11T04:11:07.123456789+00:00"))
        XCTAssertNotNil(History.parse("2026-09-11T04:11:07Z"))
        XCTAssertNil(History.parse("not a date"))
    }

    func testAgoIsRelativeAndRefusesToInventOne() {
        let now = Date()
        let t = { (s: TimeInterval) -> String in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f.string(from: now.addingTimeInterval(-s))
        }
        XCTAssertEqual(History.ago(t(10),    now: now), "JUST NOW")
        XCTAssertEqual(History.ago(t(600),   now: now), "10 MIN AGO")
        XCTAssertEqual(History.ago(t(7200),  now: now), "2 HR AGO")
        XCTAssertEqual(History.ago(t(172800), now: now), "2 DAY AGO")
        // Unparseable returns the raw string — never a confident wrong time.
        XCTAssertEqual(History.ago("garbage", now: now), "garbage")
    }

    // MARK: - the transcript

    /// The row that would have been silently deleted.
    ///
    /// A persisted tool turn is `role: "tool", content: ""` — empty by
    /// construction, because `agent_loop` puts the payload in `tool_results`
    /// and the bridge record does not carry it. An emptiness guard applied
    /// uniformly drops every tool row the loop has ever written, and the
    /// transcript then claims the answer arrived with no tool call.
    func testAnEmptyToolRowSurvivesAndAnEmptyTextRowDoesNot() {
        let rows = History.rows(from: [
            msg("user", "read the workspace"),
            msg("tool", ""),
            msg("assistant", "there are five files"),
            msg("user", "   "),          // whitespace-only: nothing was said
            msg("system", "persona"),    // filtered in the bridge; belt too
        ])
        XCTAssertEqual(rows.map(\.kind), [.user, .tool, .assistant])
        XCTAssertEqual(rows[1].text, "[TOOL]")
        // Vacuity: the tool row must not be indistinguishable from a blank.
        XCTAssertFalse(rows[1].text.isEmpty)
    }

    /// A named tool renders in the same vocabulary the live pump emits —
    /// `[LIST_DIR]`, not a second spelling for the same event.
    func testANamedToolRowUsesTheLivePumpsMarkerShape() {
        let rows = History.rows(from: [msg("tool", "list_dir")])
        XCTAssertEqual(rows.first?.text, "[LIST_DIR]")
    }

    /// An unknown fourth role is DROPPED, not rendered as a guessed kind.
    func testAnUnknownRoleIsDroppedRatherThanGuessed() {
        XCTAssertTrue(History.rows(from: [msg("wizard", "hello")]).isEmpty)
        // POS control in the same invocation: a known role in the same shape
        // DOES produce a row, so the emptiness above is about the ROLE.
        XCTAssertEqual(History.rows(from: [msg("user", "hello")]).count, 1)
    }

    func testTranscriptSummaryDistinguishesNoCoreFromNoTurns() {
        XCTAssertEqual(History.transcriptSummary(rowCount: nil), "NO CORE")
        XCTAssertEqual(History.transcriptSummary(rowCount: 0), "THIS SESSION HAS NO TURNS")
        XCTAssertEqual(History.transcriptSummary(rowCount: 3), "3 TURNS")
        XCTAssertNotEqual(History.transcriptSummary(rowCount: nil),
                          History.transcriptSummary(rowCount: 0))
    }

    // MARK: - the census: the exports must have a PRODUCTION consumer

    /// `sessions()` and `messages(sessionId:)` were the last two dark exports.
    /// Every decision leg above passes over a pure function that no screen
    /// calls — the same "correct, live, structurally unreachable" defect this
    /// project has now hit at four layers. So: assert the call sites exist in
    /// `Sources/ZeusApp`, on CODE lines.
    ///
    /// Code-lines-only is mandatory, not hygiene: `History.swift`'s own doc
    /// comments discuss `sessions()` and `messages(id)` at length, so a raw
    /// `contains` is satisfied by PROSE ABOUT the very wiring it exists to
    /// detect. Same family as the `.filter` line that counted itself.
    func testTheDarkExportsHaveProductionCallers() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/ZeusApp")

        var codeLines: [String] = []
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        for f in files {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            for raw in text.components(separatedBy: .newlines) {
                let t = raw.trimmingCharacters(in: .whitespaces)
                // The block-comment opener is ASSEMBLED, not written: this
                // repo's separator/network guards use a line-oriented
                // stripper that REFUSES a file containing a literal opener
                // rather than half-parsing it — and it faulted on this very
                // file. The guard was right; the literal is the defect.
                let blockOpen = "/" + "*"
                guard !t.hasPrefix("//"), !t.hasPrefix("///"), !t.hasPrefix("*"),
                      !t.hasPrefix(blockOpen) else { continue }
                codeLines.append(t)
            }
        }
        XCTAssertFalse(codeLines.isEmpty, "POS control: the source scan found no code lines")

        // Needles assembled, so THIS file does not contain the literals it
        // searches for — the self-matching fault, one layer up.
        let sessionsNeedle = "." + "sessions()"
        let messagesNeedle = "." + "messages(sessionId:"
        XCTAssertTrue(codeLines.contains { $0.contains(sessionsNeedle) },
                      "sessions() has no production caller — the export is still dark")
        XCTAssertTrue(codeLines.contains { $0.contains(messagesNeedle) },
                      "messages(sessionId:) has no production caller — the export is still dark")
    }
}
