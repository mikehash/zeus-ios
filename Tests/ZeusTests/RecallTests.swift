import XCTest
@testable import Zeus

/// C1 — `remember` and the file index, wired.
///
/// Every leg here runs against `Recall`, which is pure over its inputs,
/// because a SwiftUI `var body` has no importable surface in this target.
/// The seam is the same one `ProviderCatalog.grouped` uses and for the same
/// measured reason.
final class RecallTests: XCTestCase {

    // MARK: - factToWrite

    /// THE NEWLINE LEG, and it is the one that justifies the function existing
    /// at all. The core appends `\n- [ts] fact` verbatim to `MEMORY.md`, so a
    /// newline inside the fact forges a SECOND bullet with no timestamp — one
    /// call producing two entries, the later one undated and unattributable.
    func testANewlineInTheFactCannotForgeASecondBullet() {
        let out = Recall.factToWrite(from: "first line\nsecond line")
        XCTAssertEqual(out, "first line second line")
        XCTAssertFalse(out!.contains("\n"),
                       "a newline here becomes a second undated bullet in MEMORY.md")
        // CRLF and bare CR are the same defect through different doors.
        XCTAssertEqual(Recall.factToWrite(from: "a\r\nb"), "a b")
        XCTAssertEqual(Recall.factToWrite(from: "a\rb"), "a b")
    }

    /// The two arms of "nothing to write" — and the POS that a real fact is
    /// NOT nil, without which a function that returned nil for everything
    /// would pass both refusals.
    func testWhitespaceOnlyIsNotAFactButRealTextIs() {
        XCTAssertNil(Recall.factToWrite(from: ""))
        XCTAssertNil(Recall.factToWrite(from: "   \n\t  "))
        XCTAssertNotNil(Recall.factToWrite(from: "the operator prefers dark mode"),
                        "POS: a real fact must survive, or the refusals prove nothing")
    }

    /// The cap truncates and SAYS SO. An ellipsis-free truncation reads as a
    /// complete short fact, which is a silent corruption of the record.
    func testAnOversizedFactIsTruncatedVisibly() {
        let long = String(repeating: "x", count: Recall.factCap + 50)
        let out = Recall.factToWrite(from: long)!
        XCTAssertEqual(out.count, Recall.factCap + 1)   // + the ellipsis
        XCTAssertTrue(out.hasSuffix("…"))
        // POS: a fact AT the cap is untouched and carries no ellipsis, so the
        // marker means truncation rather than decoration.
        let atCap = String(repeating: "y", count: Recall.factCap)
        XCTAssertEqual(Recall.factToWrite(from: atCap), atCap)
        XCTAssertFalse(Recall.factToWrite(from: atCap)!.hasSuffix("…"))
    }

    // MARK: - rememberToast

    /// FOUR OUTCOMES, FOUR DISTINCT STRINGS. Three of these four wrote
    /// nothing; a toast vocabulary that collapsed any two would report a
    /// write that did not happen. Asserted as a SET so a future fifth arm
    /// cannot silently duplicate an existing string.
    func testEveryRememberOutcomeIsDistinguishableToTheOperator() {
        let outcomes: [Recall.RememberOutcome] = [
            .written, .noCore, .empty, .failed("io error"),
        ]
        let toasts = outcomes.map(Recall.rememberToast)
        XCTAssertEqual(Set(toasts).count, outcomes.count,
                       "two outcomes rendering the same string is a false success report")
        // The written arm must not be reachable by any of the failures — the
        // specific confusion that matters.
        for t in toasts.dropFirst() {
            XCTAssertNotEqual(t, Recall.rememberToast(.written))
        }
    }

    /// The core's own message survives into the toast. A generic "write
    /// failed" discards the one string that says WHY.
    func testTheFailureToastCarriesTheCoresReason() {
        let t = Recall.rememberToast(.failed("no workspace"))
        XCTAssertTrue(t.contains("NO WORKSPACE"), t)
    }

    // MARK: - queryToRun

    /// An unfilled field is NOT an empty-string search. `FileIndex` tokenises
    /// the query, so `""` scores nothing and returns `[]` — indistinguishable
    /// at the result from "searched and found nothing."
    func testAnUnfilledFieldIsNotAQuery() {
        XCTAssertNil(Recall.queryToRun(from: "   "))
        XCTAssertEqual(Recall.queryToRun(from: "  SOUL  "), "SOUL",
                       "POS: a real query survives, trimmed")
    }

    // MARK: - findSummary  (the vacuity probe)

    /// THE LEG THIS WHOLE SURFACE EXISTS FOR.
    ///
    /// Zero hits over an EMPTY index and zero hits over a POPULATED one are
    /// different facts: the first says the core indexed nothing, the second
    /// says the term is not among the files it has. Folded together, a broken
    /// scan is indistinguishable from a bad query — which is precisely what
    /// `index_size`'s own doc calls itself a probe against.
    func testZeroHitsMeansSomethingDifferentOverAnEmptyIndex() {
        let overEmpty = Recall.findSummary(query: "soul", hitCount: 0, indexSize: 0)
        let overFull  = Recall.findSummary(query: "soul", hitCount: 0, indexSize: 5)
        XCTAssertNotEqual(overEmpty, overFull,
                          "a broken scan must not read the same as a bad query")
        XCTAssertTrue(overFull.contains("5"),
                      "the denominator is the fact that makes the zero readable: \(overFull)")
    }

    /// `nil` index is NOT folded into empty — "no core to ask" and "a core
    /// that answered zero" are different, the same rule `mnemosyneValue` runs.
    func testNoCoreIsNotAnEmptyIndex() {
        XCTAssertNotEqual(Recall.findSummary(query: nil, hitCount: 0, indexSize: nil),
                          Recall.findSummary(query: nil, hitCount: 0, indexSize: 0))
    }

    /// Not-yet-asked vs asked-and-empty, over the SAME index size. Without
    /// this, the summary could read `INDEX EMPTY` forever and pass every
    /// other leg.
    func testAskedAndUnaskedReadDifferentlyOverTheSameIndex() {
        let unasked = Recall.findSummary(query: nil,     hitCount: 0, indexSize: 5)
        let asked   = Recall.findSummary(query: "zzz",   hitCount: 0, indexSize: 5)
        let hit     = Recall.findSummary(query: "soul",  hitCount: 1, indexSize: 5)
        XCTAssertEqual(Set([unasked, asked, hit]).count, 3,
                       "three states, three strings: \(unasked) / \(asked) / \(hit)")
    }

    // MARK: - row rendering

    func testTheDirectoryLabelDropsTheFileNameAndAbstainsAtTheRoot() {
        XCTAssertEqual(Recall.dirLabel(for: "memory/MEMORY.md"), "memory")
        XCTAssertEqual(Recall.dirLabel(for: "a/b/c.md"), "a/b")
        XCTAssertNil(Recall.dirLabel(for: "SOUL.md"),
                     "a root file has no directory to report")
    }

    /// Two different scores must render differently — a formatter that
    /// rounded everything to one value would make every row look identical
    /// over an index whose postings are all file-name tokens.
    func testScoresThatDifferRenderDifferently() {
        XCTAssertNotEqual(Recall.scoreLabel(3.0), Recall.scoreLabel(1.5))
        XCTAssertEqual(Recall.scoreLabel(3.0), "3.00")
    }

    // MARK: - the wiring itself

    /// THE GATE-TWO LEG. Every assertion above is about `Recall` being
    /// CORRECT; none of them is about `Recall` being REACHED. A pure helper
    /// with perfect legs and no caller is the dark-export state this commit
    /// exists to leave — `remember` and `search` each read 0 consumers at the
    /// walk while both were exported, tested and green in the bridge.
    ///
    /// CODE LINES ONLY, with a stripper control. Fifth instance of the family
    /// on this branch: the needle is the call form `core.remember(fact:`, and
    /// the doc comments in both files NAME those exports to explain the cut —
    /// a whole-file read counts the explanation as a call site and passes in a
    /// world where nothing calls anything.
    func testTheDarkExportsAreActuallyCalledFromTheApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/ZeusApp")

        func codeLines(_ file: String) throws -> [String] {
            let src = try String(contentsOf: root.appendingPathComponent(file),
                                 encoding: .utf8)
            return src.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                          && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
        }

        let rootView = try codeLines("RootView.swift")
        let nodes    = try codeLines("NodesView.swift")

        // STRIPPER CONTROL. If the filter above ate everything — a wrong path,
        // a changed comment syntax — every count below is zero and the
        // assertions become unfalsifiable refusals rather than measurements.
        XCTAssertGreaterThan(rootView.count, 100, "stripper ate RootView")
        XCTAssertGreaterThan(nodes.count, 100, "stripper ate NodesView")

        let remembers = rootView.filter { $0.contains("core.remember(fact:") }
        XCTAssertEqual(remembers.count, 1,
                       "remember must be called exactly once, from RootView.remember")

        let searches = nodes.filter { $0.contains("core.search(query:") }
        XCTAssertEqual(searches.count, 1,
                       "search must be called exactly once, from NodesView.runFind")

        // THE NEEDLE-CHOICE CONTROL, and its first draft was itself wrong —
        // it asserted the prose sat in `RootView` when it sits in
        // `SessionView`, one file over. The claim being measured is that the
        // CALL form (`core.remember(fact:`) was necessary and the bare form
        // (`remember(fact:`) would have been self-matching: the loose needle
        // hits a doc comment that explains the export, in a file that calls
        // nothing. Measured on both sides so the choice is a reading, not a
        // preference.
        func raw(_ file: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        }
        let sessionRaw = try raw("SessionView.swift")
        XCTAssertTrue(sessionRaw.contains("remember(fact:"),
                      "the LOOSE needle matches prose in a file with no call site")
        XCTAssertFalse(sessionRaw.contains("core.remember(fact:"),
                       "the CALL needle does not — which is why it is the needle")
    }
}
