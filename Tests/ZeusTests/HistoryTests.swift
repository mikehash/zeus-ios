import XCTest
@testable import Zeus

/// C — legs for the session list and the transcript.
///
/// Two-arm everywhere: the ruling's own words were "the two-arm empty/two-row
/// leg", because "the export returns nothing" and "the view ignores the
/// export" render identically under a one-arm test.
final class HistoryTests: XCTestCase {

    /// Re-targeted from `SessionInfo` to `SessionRow` in the S3a commit. The
    /// factory keeps its `String` argument so the twelve existing legs read
    /// unchanged; `row(_:nil)` below is the new shape only the gateway path
    /// can produce.
    private func info(_ id: String, _ ts: String) -> SessionRow {
        SessionRow(id: id, sortKey: ts)
    }
    private func unranked(_ id: String) -> SessionRow {
        SessionRow(id: id, sortKey: nil)
    }
    private func msg(_ role: String, _ content: String,
                     toolName: String? = nil) -> TurnMessage {
        TurnMessage(role: role, content: content,
                    timestampRfc3339: "2026-09-11T04:00:00Z",
                    toolName: toolName)
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

    // MARK: - the four legs of the index-decorated comparator

    /// LEG 1 — the remote path. Every key is `nil` (the gateway's
    /// `GET /v1/sessions` emits `created` and no `updated`, so the conformer
    /// has no honest key to send) and the `created` values are SHUFFLED, so a
    /// comparator that quietly fell back to creation time would be caught too.
    /// Ids are deliberately in REVERSE alphabetical order: under the arm this
    /// replaces (`a.id < b.id`) the list would come back re-sorted, which is
    /// the whole defect — server order is what the screen claims.
    func testARemoteListWithNoKeysRendersInServerOrder() {
        let server = [info("zeta",  ""),
                      info("mid",   ""),
                      info("alpha", "")]
        let out = History.newestFirst(server)
        XCTAssertEqual(out.map(\.id), ["zeta", "mid", "alpha"])
        // Vacuity: server order and alphabetical order must be DIFFERENT
        // orders here, or this leg would pass under the id tiebreak it exists
        // to refuse.
        XCTAssertNotEqual(server.map(\.id), server.map(\.id).sorted())
    }

    /// LEG 2 — the embedded path, stated as its own leg because it is a
    /// BEHAVIOUR CHANGE and not an accident: two unparseable local rows used
    /// to come back alphabetical and now come back in file order. Alphabetical
    /// was the costume defect `History.swift`'s own note names, so this is an
    /// improvement; naming it here keeps a future reader from "fixing" it back.
    func testTwoUnparseableLocalRowsKeepInputOrder() {
        let out = History.newestFirst([info("zzz-written-first", "garbage"),
                                       info("aaa-written-second", "not-a-date")])
        XCTAssertEqual(out.map(\.id), ["zzz-written-first", "aaa-written-second"])
    }

    /// LEG 3 — mixed. Parsed rows sort newest-first ABOVE; unparsed rows sink
    /// below and hold input order among themselves. The unparsed pair is
    /// interleaved with the parsed pair in the input precisely so that "sinks
    /// below" and "keeps input order" are two separate facts this leg reads.
    func testParsedRowsSortAboveUnparsedWhichKeepInputOrder() {
        let out = History.newestFirst([info("old",       "2026-09-11T04:00:00Z"),
                                       info("junk-first", "garbage"),
                                       info("new",       "2026-09-11T06:00:00Z"),
                                       info("junk-second", "")])
        XCTAssertEqual(out.map(\.id), ["new", "old", "junk-first", "junk-second"])
    }

    /// LEG 4 — the ordering is a STRICT WEAK ORDERING, which the ruling's
    /// literal wording ("any pair without two parsed keys orders by index")
    /// is not. Counterexample it would have shipped: A(idx 0, old),
    /// B(idx 1, nil), C(idx 2, new) — A<B by index, B<C by index, C<A by
    /// date, a cycle, and `sorted(by:)` with a non-SWO predicate is
    /// UNDEFINED BEHAVIOUR, not merely a wrong order. This leg asserts the
    /// property directly on the shape that produced the cycle rather than
    /// trusting that one sorted output looked right.
    func testTheComparatorIsAStrictWeakOrdering() {
        let cyclic = [info("A-old",  "2026-09-11T04:00:00Z"),
                      info("B-nil",  "garbage"),
                      info("C-new",  "2026-09-11T06:00:00Z")]
        // The parsed pair ranks by time; the unparsed row sinks below BOTH,
        // never between them — which is what having no cycle means here.
        XCTAssertEqual(History.newestFirst(cyclic).map(\.id),
                       ["C-new", "A-old", "B-nil"])
        // And the property is order-independent: every input permutation of
        // the same rows must yield the same answer. A non-SWO comparator does
        // not guarantee that, and this is the assertion the index-in-every-arm
        // form fails.
        let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2],
                            [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for p in permutations {
            XCTAssertEqual(History.newestFirst(p.map { cyclic[$0] }).map(\.id),
                           ["C-new", "A-old", "B-nil"],
                           "permutation \(p) disagreed")
        }
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

    /// The joined name renders in the LIVE pump's vocabulary.
    ///
    /// The bridge now recovers the tool's name by matching the persisted
    /// `ToolResult.call_id` against the preceding assistant turn's
    /// `ToolCall.id` — the tool row itself has no name field. Before this,
    /// replay said `[TOOL]` where the live reply said `[READ_FILE]`: the same
    /// event, two spellings, which an operator reads as two different things.
    func testAJoinedToolNameRendersAsTheLiveMarker() {
        let rows = History.rows(from: [
            msg("user", "read my notes"),
            msg("assistant", ""),
            msg("tool", "", toolName: "read_file"),
        ])
        XCTAssertEqual(rows.last?.text, "[READ_FILE]",
                       "a joined name must render in the live pump's shape")
        // Vacuity: this must DIFFER from the unnamed fallback, or the leg is
        // satisfied by a renderer that ignores the name entirely.
        let unnamed = History.rows(from: [msg("tool", "")])
        XCTAssertNotEqual(rows.last?.text, unnamed.last?.text,
                          "named and unnamed rows MUST render differently")
    }

    /// `nil` toolName — the join found no match — keeps the generic marker.
    ///
    /// This is the degrade path, and it is the one that must never invent a
    /// name: a wrong tool name reads as fact, a generic marker is visibly
    /// generic. An empty-string name is treated as no name for the same
    /// reason — `[]` is not a marker, it is a rendering bug.
    func testAnUnjoinedToolRowKeepsTheGenericMarker() {
        XCTAssertEqual(History.rows(from: [msg("tool", "", toolName: nil)]).last?.text,
                       "[TOOL]")
        XCTAssertEqual(History.rows(from: [msg("tool", "", toolName: "")]).last?.text,
                       "[TOOL]", "an empty name is not a name")
        XCTAssertEqual(History.rows(from: [msg("tool", "", toolName: "   ")]).last?.text,
                       "[TOOL]", "a whitespace name is not a name")
    }

    /// The name WINS over content when both are present.
    ///
    /// A tool row's content is empty by construction, so this ordering is
    /// invisible in practice — until some other writer fills it, at which
    /// point content-first would shadow the authoritative joined name with
    /// whatever text happened to be in the row.
    func testTheJoinedNameTakesPrecedenceOverRowContent() {
        let rows = History.rows(from: [msg("tool", "stale text", toolName: "list_dir")])
        XCTAssertEqual(rows.last?.text, "[LIST_DIR]",
                       "the joined name is authoritative; content is the fallback")
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

    // MARK: - S3a: the Optional sort key

    /// THE KEY IS ABSENT, NOT UNPARSEABLE — and the distinction is the whole
    /// reason `SessionRow` exists.
    ///
    /// A gateway row carries `nil`, which no `SessionInfo` could hold: its
    /// `updatedAtRfc3339` is a UniFFI-generated non-Optional `String`. The
    /// rejected alternative was `""`, and the vacuity assertion below is what
    /// refuses it: an empty string renders through `ago` as itself, so a
    /// sentinel and an absence would have produced DIFFERENT screens while
    /// passing the same sort legs.
    func testAnAbsentSortKeyRendersNothingAndIsNotTheEmptyString() {
        XCTAssertEqual(History.ago(nil), "")
        // `""` renders the same and SORTS the same — it parses to nil, so the
        // comparator cannot tell a sentinel from an absence either. That is
        // exactly why the sentinel had to be refused AT THE CONFORMER
        // (`GatewayCapabilitiesTests.testTheGatewayListHasNoSortKeyAtAll`)
        // rather than here: no leg downstream of the row type can see it.
        XCTAssertEqual(History.ago(""), "")
        XCTAssertNil(SessionRow(id: "x", sortKey: nil).sortKey)
        XCTAssertNotNil(SessionRow(id: "x", sortKey: "").sortKey,
                        "the TYPE distinguishes them even though the sort cannot")
        XCTAssertEqual(History.ago("garbage"), "garbage",
                       "an unparseable key still shows what the backend SENT")
        XCTAssertNotEqual(History.ago(nil), History.ago("2026-09-11T04:00:00Z"))
    }

    /// SERVER ORDER is a claim about the LIST, and it is only true when
    /// nothing in it can be ranked.
    ///
    /// Three arms, because the tempting one-arm version ("any nil ⇒ server
    /// order") would print SERVER ORDER over a list this screen really did
    /// sort — a false statement about the rankable rows sitting above the
    /// sinks.
    func testServerOrderIsClaimedOnlyWhenNothingCanBeRanked() {
        XCTAssertTrue(History.isServerOrder([unranked("a"), unranked("b")]))
        XCTAssertFalse(History.isServerOrder([unranked("a"),
                                              info("b", "2026-09-11T04:00:00Z")]),
                       "a mixed list IS partly ordered by this screen")
        XCTAssertFalse(History.isServerOrder([]),
                       "an empty list has no order to make a claim about")
        // Composed through `Theme.joined`, NOT re-typed here. The separator is
        // `\u{00A0}·\u{00A0}` — the NBSPs are load-bearing (they stop the dot
        // stranding at a line end) and invisible, so a hand-typed literal in
        // this leg would red on a difference no reader can see in the failure
        // message. Asserting the composition also means a change to the
        // separator cannot break this leg for a reason unrelated to it.
        XCTAssertEqual(History.listSummary(sessionCount: 2, serverOrder: true),
                       Theme.joined(["2 SESSIONS", "SERVER ORDER"]))
        XCTAssertTrue(History.listSummary(sessionCount: 2, serverOrder: true)
                        .hasSuffix("SERVER ORDER"))
        XCTAssertEqual(History.listSummary(sessionCount: 2), "2 SESSIONS")
        XCTAssertNotEqual(History.listSummary(sessionCount: 2, serverOrder: true),
                          History.listSummary(sessionCount: 2))
    }

    /// A full gateway list keeps INPUT ORDER — the `(nil, nil)` index arm,
    /// now reached by every pair rather than by a stray one.
    ///
    /// Ids are deliberately reverse-alphabetical so that server order and the
    /// old id tiebreak DIFFER on this input; without that the leg would pass
    /// under the very comparator it exists to refuse.
    func testAGatewayListWithNoKeysAtAllKeepsServerOrder() {
        let server = [unranked("zzz-first"), unranked("mmm-second"), unranked("aaa-third")]
        XCTAssertEqual(History.newestFirst(server).map(\.id),
                       ["zzz-first", "mmm-second", "aaa-third"])
        XCTAssertNotEqual(History.newestFirst(server).map(\.id),
                          server.map(\.id).sorted(),
                          "input order and alphabetical order must DIFFER here")
    }
}
