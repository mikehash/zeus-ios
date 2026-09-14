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
        let overEmpty = Recall.findSummary(query: "soul", fileHits: 0, indexSize: 0)
        let overFull  = Recall.findSummary(query: "soul", fileHits: 0, indexSize: 5)
        XCTAssertNotEqual(overEmpty, overFull,
                          "a broken scan must not read the same as a bad query")
        XCTAssertTrue(overFull.contains("5"),
                      "the denominator is the fact that makes the zero readable: \(overFull)")
    }

    /// `nil` index is NOT folded into empty — "no core to ask" and "a core
    /// that answered zero" are different, the same rule `mnemosyneValue` runs.
    func testNoCoreIsNotAnEmptyIndex() {
        XCTAssertNotEqual(Recall.findSummary(query: nil, fileHits: 0, indexSize: nil),
                          Recall.findSummary(query: nil, fileHits: 0, indexSize: 0))
    }

    /// Not-yet-asked vs asked-and-empty, over the SAME index size. Without
    /// this, the summary could read `INDEX EMPTY` forever and pass every
    /// other leg.
    func testAskedAndUnaskedReadDifferentlyOverTheSameIndex() {
        let unasked = Recall.findSummary(query: nil,     fileHits: 0, indexSize: 5)
        let asked   = Recall.findSummary(query: "zzz",   fileHits: 0, indexSize: 5)
        let hit     = Recall.findSummary(query: "soul",  fileHits: 1, indexSize: 5)
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

    // MARK: - Step B  the relabel, and the two things that keep it honest

    /// Repo root from this file's own path — the same derivation
    /// `AutoSendSeamTests` and `BackstepTests` use.
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
    }

    /// THE LEG THE RELABEL EXISTS BEHIND.
    ///
    /// `MEMORY SEARCH` is only an honest label while the bridge actually
    /// indexes CONTENT. At pin `2bfc08aa` it did not — `with_tags` had zero
    /// call sites, every posting was a file NAME, and a fact written by
    /// REMEMBER was unfindable permanently. `d5619c8` fixed that.
    ///
    /// The failure mode this guards is a PIN MOVE: nothing about a Swift
    /// string knows which Rust it ships against, so a re-pin to a sha without
    /// content tokens would silently restore the exact screen C1 refused to
    /// build. This reads the bridge source in the tree and reds instead.
    ///
    /// The needle is built with `+` so this test file does not itself contain
    /// the literal — the same repair as the bridge's own call-site census,
    /// which counted its own `.filter` line as a third call site.
    func testTheLabelIsBackedByTheRust() throws {
        let bridge = repoRoot()
            .appendingPathComponent("rust/zeus-core-bridge/src/lib.rs")
        let src = try String(contentsOf: bridge, encoding: .utf8)

        // Code lines only: the file's doc comments discuss both builders at
        // length, so a raw `contains` is satisfied by PROSE about the very
        // absence it is meant to detect.
        let code = src.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }

        let tagsCall = "with_" + "tags("
        let tagged = code.filter { $0.contains(tagsCall) }
        XCTAssertFalse(tagged.isEmpty, """
            MEMORY SEARCH is on screen but the bridge does not call \
            with_tags on any code line — the index is filenames again and \
            the label is a lie. Either re-pin forward or relabel FIND A FILE.
            """)

        // POS control, same invocation: a needle known to be PRESENT proves
        // the stripper did not eat the file. Without it, a bad path or an
        // over-eager filter returns "0 hits" and reads as the defect.
        let addCall = "index." + "add("
        XCTAssertFalse(code.filter { $0.contains(addCall) }.isEmpty,
                       "control needle absent — this measured the wrong text, not the wrong Rust")

        // The 1.0 tier stays empty ON PURPOSE (indexer.rs:213-221 does not
        // de-duplicate first_line postings, so a file repeating one word 500
        // times outranks the file NAMED for it — measured, it failed a leg).
        // Asserting its absence is what stops a future hand "completing" the
        // pair and silently re-introducing the unbounded-posting defect.
        let firstLineCall = "with_first_" + "line("
        XCTAssertTrue(code.filter { $0.contains(firstLineCall) }.isEmpty, """
            the first_line tier is populated — that tier does not de-duplicate, \
            so repetition can outrank a name. If this is deliberate, the \
            dedup leg in the bridge must move with it.
            """)
    }

    /// The old label is GONE from the shipped sources, not merely
    /// out-numbered by the new one.
    ///
    /// A relabel that adds `MEMORY SEARCH` while leaving `FIND A FILE` on a
    /// second surface passes any "does the new string exist" assertion and
    /// ships two names for one feature. Both arms are asserted so the
    /// verdict is a reading, not a preference.
    func testTheSurfaceCarriesExactlyOneNameForItself() throws {
        let app = repoRoot().appendingPathComponent("Sources/ZeusApp")
        let files = try FileManager.default
            .contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 5,
                             "no sources enumerated — the verdict below is vacuous")

        let oldLabel = "FIND A " + "FILE"
        let newLabel = "MEMORY " + "SEARCH"
        var renders: [String] = []
        var stale: [String] = []
        for f in files {
            let code = try String(contentsOf: f, encoding: .utf8)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
            if code.contains(where: { $0.contains("Text(\"\(newLabel)\")") }) {
                renders.append(f.lastPathComponent)
            }
            if code.contains(where: { $0.contains("\"\(oldLabel)\"") }) {
                stale.append(f.lastPathComponent)
            }
        }
        XCTAssertEqual(renders, ["NodesView.swift"],
                       "the new label renders from \(renders), expected exactly NodesView")
        XCTAssertTrue(stale.isEmpty,
                      "the old label still ships on code lines in \(stale) — two names, one feature")
    }

    /// The hit-and-miss fixture, over a REMEMBERED fact rather than a
    /// filename — the shape of the round trip the label now promises.
    ///
    /// `findSummary` is the decision under test, so the arms are the three
    /// readings the operator can get after typing a fact they just saved:
    /// found it, index has files but not that, index is empty.
    func testARememberedFactReadsAsFoundNotAsABadQuery() {
        let found   = Recall.findSummary(query: "zebraquorum", fileHits: 1, indexSize: 6)
        let missing = Recall.findSummary(query: "zebraquorum", fileHits: 0, indexSize: 6)
        let noIndex = Recall.findSummary(query: "zebraquorum", fileHits: 0, indexSize: 0)

        XCTAssertNotEqual(found, missing,
                          "a found fact and a missing one must not read alike")
        XCTAssertNotEqual(missing, noIndex,
                          "a term absent from 6 files must not read like an unbuilt index")
        XCTAssertTrue(found.contains("6"),
                      "the denominator survives a HIT too, not just a zero: \(found)")
    }

    // MARK: - READING, and the drop (S3b)

    /// `READING` IS A FOURTH STRING. A search launched while the size read is
    /// still in flight must not report the index empty: "not measured yet" and
    /// "measured and holds nothing" are different facts, and folding them
    /// tells the operator their memory is empty when it may be full.
    func testAnInFlightReadIsNotAnEmptyIndex() {
        let reading = Recall.findSummary(query: "zeus", fileHits: 0, indexSize: nil, reading: true)
        let empty   = Recall.findSummary(query: "zeus", fileHits: 0, indexSize: 0)
        let noCore  = Recall.findSummary(query: "zeus", fileHits: 0, indexSize: nil)

        XCTAssertEqual(reading, "READING")
        XCTAssertNotEqual(reading, empty,
                          "a search during a read must not claim the index is empty")
        XCTAssertNotEqual(reading, noCore,
                          "a read in flight is not the absence of a core to read")
        XCTAssertNotEqual(empty, noCore,
                          "VACUITY: the two pre-existing strings must still differ, or this leg proves nothing about the third")
    }

    /// THE READ OUTRANKS THE COUNT. While a read is in flight every sentence
    /// with a denominator in it quotes a number we do not have.
    func testAReadInFlightOutranksAStaleCount() {
        XCTAssertEqual(Recall.findSummary(query: nil, fileHits: 0, indexSize: 99, reading: true),
                       "READING")
        XCTAssertEqual(Recall.findSummary(query: "q", fileHits: 3, indexSize: 99, reading: true),
                       "READING")
        XCTAssertNotEqual(Recall.findSummary(query: "q", fileHits: 3, indexSize: 99, reading: false),
                          "READING",
                          "VACUITY: a settled read must NOT say READING, or the flag is ignored")
    }

    /// THE SAME FOURTH STRING IN THE ROW. Both readers of one reading, so the
    /// row and the summary cannot disagree about whether the index is known.
    func testTheRowSaysReadingRatherThanNoCore() {
        XCTAssertEqual(NodesView.mnemosyneValue(indexSize: nil, reading: true), "READING")
        XCTAssertNotEqual(NodesView.mnemosyneValue(indexSize: nil, reading: true),
                          NodesView.mnemosyneValue(indexSize: nil),
                          "an unread index must not render as NO CORE")
        XCTAssertNotEqual(NodesView.mnemosyneValue(indexSize: nil, reading: true),
                          NodesView.mnemosyneValue(indexSize: 0),
                          "an unread index must not render as INDEX EMPTY")
        XCTAssertEqual(NodesView.mnemosyneValue(indexSize: 6, reading: false), "6 FILES INDEXED")
    }

    /// THE DROP, ASSERTED AS A DROP. A superseded query's result is discarded
    /// rather than written — not merely "the hits changed", which passes in
    /// the world where the stale write wins the race.
    func testASupersededSearchResultIsDropped() {
        XCTAssertFalse(Recall.mayWriteResult(generation: 1, current: 2),
                       "a result from a query the operator has already replaced must not be rendered")
        XCTAssertFalse(Recall.mayWriteResult(generation: 1, current: 5))
        XCTAssertTrue(Recall.mayWriteResult(generation: 2, current: 2),
                      "VACUITY: the current generation MUST be writable, or the guard drops everything")
    }

    /// ONE DEFINITION, ONE PRODUCTION CALLER. A predicate leg is only a leg on
    /// the SHIPPED guard if the symbol the test calls is the symbol the view
    /// calls. Two definitions — a helper and a near-copy inlined in the view —
    /// and the green above proves a property of the copy while the view still
    /// writes stale. So: exactly one `static func mayWriteResult` in Sources,
    /// and exactly one call of it, in `NodesView`.
    func testTheGuardHasOneDefinitionAndTheViewCallsIt() throws {
        let recall = try codeLinesJoined("Recall.swift")
        let nodes  = try codeLinesJoined("NodesView.swift")

        // STRIPPER CONTROLS. If the reader or the comment-filter ate the file,
        // every count below is zero and the assertions become unfalsifiable.
        XCTAssertGreaterThan(recall.count, 40, "VOID: stripper ate Recall.swift")
        XCTAssertGreaterThan(nodes.count, 100, "VOID: stripper ate NodesView.swift")

        let defs = recall.filter { $0.contains("static func mayWriteResult(") }
        XCTAssertEqual(defs.count, 1,
                       "mayWriteResult must have exactly ONE definition — a second lets the leg pass against a copy")

        let defsElsewhere = nodes.filter { $0.contains("func mayWriteResult(") }
        XCTAssertEqual(defsElsewhere.count, 0,
                       "the view must not define its own mayWriteResult — it must call Recall's")

        let callers = nodes.filter { $0.contains("Recall.mayWriteResult(") }
        XCTAssertEqual(callers.count, 1,
                       "exactly one production call site, in runFind — the drop happens in one place or not at all")

        // POS CONTROL: a symbol known present in the same stripped text, so a
        // zero above is a statement about mayWriteResult and not about the reader.
        XCTAssertGreaterThan(nodes.filter { $0.contains("core.search(query:") }.count, 0,
                             "VOID: the counter matches nothing at all in NodesView")
        // NEG CONTROL: a symbol known absent, so the counter is not matching everything.
        XCTAssertEqual(nodes.filter { $0.contains("Recall.zzzNoSuchGuard(") }.count, 0)
    }

    /// THE WRITE IS GUARDED, NOT MERELY THE PREDICATE CORRECT. A true
    /// `mayWriteResult == false` is worth nothing if `runFind` writes
    /// `findHits` before consulting it — predicate-true-but-write-anyway is
    /// precisely the fault the guard exists to kill, and no value-level
    /// assertion on the predicate can see it. `runFind` is a private method on
    /// a `View`: it has no importable surface, so the ORDER inside the shipped
    /// function is readable only from source.
    func testRunFindConsultsTheGuardBeforeItWritesTheHits() throws {
        let lines = try codeLinesJoined("NodesView.swift")
        guard let start = lines.firstIndex(where: { $0.contains("private func runFind()") }),
              let end = lines[start...].firstIndex(where: { $0.contains("private func readIndexSize()") })
        else {
            return XCTFail("VOID: could not slice runFind — anchors moved, this census measured nothing")
        }
        let slice = Array(lines[start..<end])

        // SLICE CONTROL: the write we are ordering against must be INSIDE the
        // slice, or "guard precedes write" is vacuously true over an empty set.
        guard let guardAt = slice.firstIndex(where: { $0.contains("Recall.mayWriteResult(") }) else {
            return XCTFail("VOID: the guard is not inside runFind — the drop is not where the write is")
        }
        guard let writeAt = slice.firstIndex(where: { $0.contains("findHits = hits") }) else {
            return XCTFail("VOID: the hits write is not inside the slice being scanned")
        }

        XCTAssertLessThan(guardAt, writeAt,
                          "the guard must be consulted BEFORE findHits is written — a stale result must be dropped, not rendered then corrected")

        // And the guard must REFUSE, not branch into a different write: the
        // only statement it may guard is an early return.
        XCTAssertTrue(slice[guardAt].contains("else { return }"),
                      "a failed guard must drop the result — anything else renders a superseded answer")

        // Every write of findHits inside the Task is downstream of the guard.
        let writesAfterGuard = slice.enumerated().filter { $0.element.contains("findHits = hits") }
        XCTAssertEqual(writesAfterGuard.count, 1,
                       "exactly one hits write in runFind — a second could sit above the guard unnoticed")
    }

    /// Source lines of a file in Sources/ZeusApp, comments stripped. FAILS
    /// naming VOID when absent — never a skip.
    private func codeLinesJoined(_ name: String) throws -> [String] {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // repo
        let url = root.appendingPathComponent("Sources/ZeusApp/\(name)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(domain: "VOID", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "VOID: no source at \(url.path) — this census measured nothing"])
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }
    // MARK: - S5: locality, aperture, and the render branch

    /// THE FIFTH OUTCOME IS A DISTINCT SENTENCE.
    ///
    /// `.written` says `THIS DEVICE`. Reusing it for a write that went over
    /// `POST /v1/memory/remember` tells the operator their fact is on a phone
    /// that does not have it — and the fact is recoverable only from the box
    /// the sentence denied.
    func testARemoteWriteDoesNotClaimThisDevice() {
        let local  = Recall.rememberToast(.written)
        let remote = Recall.rememberToast(.writtenRemote)
        XCTAssertNotEqual(local, remote,
                          "the two write outcomes render identically — the locality " +
                          "claim survives the gateway")
        XCTAssertTrue(local.contains("THIS DEVICE"))
        XCTAssertFalse(remote.contains("THIS DEVICE"),
                       "a remote write claims the local device")
        XCTAssertTrue(remote.contains("GATEWAY"))
    }

    /// AND THE NO-CORE SENTENCE IS LOCAL-ONLY.
    ///
    /// `NO CORE ON THIS DEVICE` is false in the other direction: a gateway
    /// that refused HAS a core, elsewhere. Neither remote string may carry it.
    func testTheNoCoreSentenceNeverReachesTheGatewayArm() {
        let noCore = Recall.rememberToast(.noCore)
        XCTAssertTrue(noCore.contains("NO CORE ON THIS DEVICE"),
                      "the local no-core sentence changed — this leg's subject moved")
        for outcome in [Recall.RememberOutcome.writtenRemote] {
            XCTAssertFalse(Recall.rememberToast(outcome).contains("NO CORE"),
                           "a gateway outcome renders NO CORE — the costume defect")
            XCTAssertFalse(Recall.rememberToast(outcome).contains("THIS DEVICE"))
        }
    }

    /// THE WRITE OUTCOME IS SELECTED BY THE CONFIG ARM.
    ///
    /// Source-structural: `remember` is private on a `View` and reaches the
    /// Keychain, so no behavioural leg can watch the selection. The subject is
    /// that the choice is a `switch` on the config — NOT a nil-core probe,
    /// which would be a second measurement able to disagree with the first.
    func testTheWriteOutcomeIsChosenByTheArmAndNotAProbe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ZeusApp")
        let src = try String(contentsOf: root.appendingPathComponent("RootView.swift"),
                             encoding: .utf8)
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let start = lines.firstIndex(where: { $0.contains("private func remember(_ message: Message)") }) else {
            return XCTFail("VOID: the `remember` anchor moved — this leg measured nothing")
        }
        guard let end = lines[start...].firstIndex(where: { $0.contains("private func showToast(") }) else {
            return XCTFail("VOID: the closing anchor moved — the slice is unbounded")
        }
        let slice = lines[start..<end].joined(separator: "\n")

        XCTAssertTrue(slice.contains("case .resolved:"),
                      "the outcome is not switched on the config arm")
        XCTAssertTrue(slice.contains("success = .writtenRemote"),
                      "the `.resolved` arm does not select the remote sentence")
        XCTAssertTrue(slice.contains("makeCapabilities(for: config"),
                      "the write does not route through the resolver — it is still " +
                      "hardwired to the embedded conformer")
        // POS control: the slice contains something known present.
        XCTAssertTrue(slice.contains("Recall.rememberToast"))
        // NEG control: the needle is not matching everything.
        XCTAssertFalse(slice.contains("zzzNoSuchOutcome"))
    }

    /// A FILES COUNT NAMES ITS APERTURE.
    ///
    /// The two measurements are genuinely different — `scan_workspace`
    /// (MAX_DEPTH 6, dotfiles skipped) vs `collect_files` (neither) — so the
    /// same workspace yields two legitimate numbers, and the larger one shown
    /// bare against a gateway is a number published without the aperture that
    /// produced it.
    func testAGatewayFileCountSaysSo() {
        let local  = Recall.findSummary(query: nil, fileHits: 0, indexSize: 9)
        let remote = Recall.findSummary(query: nil, fileHits: 0, indexSize: 9,
                                        aperture: .gateway)
        XCTAssertNotEqual(local, remote,
                          "two different measurements render as the same sentence")
        XCTAssertTrue(remote.contains("GATEWAY"))
        XCTAssertFalse(local.contains("GATEWAY"))
    }

    /// A MEMORY HIT IS NOT COUNTED AS A FILE.
    ///
    /// `indexSize` is a FILES count on both arms, so a record inside that
    /// numerator is the costume one layer up from the row: `3 OF 9 FILES`
    /// when only one of the three was a file.
    func testMemoryHitsAreNotCountedInTheFilesDenominator() {
        let filesOnly = Recall.findSummary(query: "q", fileHits: 2, indexSize: 9)
        XCTAssertTrue(filesOnly.contains("2 OF 9 FILES"))
        XCTAssertFalse(filesOnly.contains("MEMOR"),
                       "a memory clause appeared with no memory hits")

        let mixed = Recall.findSummary(query: "q", fileHits: 2, indexSize: 9, memoryHits: 3)
        XCTAssertTrue(mixed.contains("2 OF 9 FILES"),
                      "the file numerator absorbed the records")
        XCTAssertTrue(mixed.contains("3 MEMORIES"))

        // A record-only result is NOT "no match": something was found, it was
        // simply not a file.
        let recordsOnly = Recall.findSummary(query: "q", fileHits: 0, indexSize: 9, memoryHits: 1)
        XCTAssertFalse(recordsOnly.contains("NO MATCH"),
                       "a hit was reported as no match because it was not a file")
        XCTAssertTrue(recordsOnly.contains("1 MEMORY"))

        // And genuinely nothing stays NO MATCH.
        XCTAssertTrue(Recall.findSummary(query: "q", fileHits: 0, indexSize: 9)
                        .contains("NO MATCH IN 9 FILES"))
    }

    /// A `.memory` HIT CANNOT REACH `dirLabel`.
    ///
    /// Not a NEG on absence — a BRANCH. `dirLabel`'s `nil` means "at the
    /// workspace root" (its own doc comment says so), so a pathless record
    /// routed through it does not render blank, it renders `WORKSPACE ROOT`:
    /// a claim about where the record lives on disk. The `switch` on `kind`
    /// makes that structurally unreachable.
    func testAMemoryHitNeverRendersAFileLocation() {
        let record = RecallHit(kind: .memory(id: "m-1",
                                             memoryType: "Semantic",
                                             content: "gate before land"),
                               score: 0.4)
        let toast = NodesView.hitToast(record)
        XCTAssertFalse(toast.contains("WORKSPACE ROOT"),
                       "a record with no path was told it lives at the workspace root")
        XCTAssertTrue(toast.contains("SEMANTIC"))
        XCTAssertTrue(toast.contains("gate before land"))

        // POS control: a FILE hit at the root DOES get that sentence, so the
        // NEG above is witnessing the branch and not the string's absence.
        let rootFile = RecallHit(kind: .file(path: "README.md", snippet: nil), score: 0.9)
        XCTAssertTrue(NodesView.hitToast(rootFile).contains("WORKSPACE ROOT"))
        let nested = RecallHit(kind: .file(path: "docs/SOUL.md", snippet: nil), score: 0.9)
        XCTAssertTrue(NodesView.hitToast(nested).contains("docs"))
    }

    /// THE ROW'S THREE FILE-SHAPED SLOTS ARE OFF THE KIND.
    ///
    /// `icon` was the hardcoded literal `"doc"` — a glyph asserting "file"
    /// before a single string is read, which is the costume defect in the form
    /// a reader meets FIRST. `label` was `SearchHit.name`, a field the memory
    /// arm does not have. Only `score` was ever shared.
    func testTheRowSlotsAreChosenByKind() {
        let file = RecallHit(kind: .file(path: "docs/SOUL.md", snippet: "x"), score: 0.5)
        let record = RecallHit(kind: .memory(id: "m", memoryType: "Episodic", content: "c"),
                               score: 0.5)
        XCTAssertNotEqual(file.icon, record.icon,
                          "both kinds render the same glyph — the icon is still a literal")
        XCTAssertEqual(file.icon, "doc")
        XCTAssertEqual(file.label, "SOUL.md", "the file label is not the leaf name")
        XCTAssertEqual(record.label, "Episodic",
                       "a record has no `name`; its type is the only honest label")
        XCTAssertEqual(Recall.scoreLabel(file.score), Recall.scoreLabel(record.score),
                       "score is the ONE kind-agnostic slot and it diverged")
        XCTAssertTrue(file.isFile)
        XCTAssertFalse(record.isFile)
    }

    /// AND THE RENDER SITE ACTUALLY CONSUMES THE KIND-DERIVED SLOTS.
    ///
    /// THE GAP THIS CLOSES, MEASURED: `testTheRowSlotsAreChosenByKind` asserts
    /// that `RecallHit.icon` DIFFERS by kind — and it stayed green under a
    /// mutation that restored the literal `icon: "doc"` at the `NodeRow` call.
    /// A correct property on a type says nothing about the view reading it;
    /// the first-order leg measures the shape, this one measures the reach.
    /// `NodeRow` is a SwiftUI view with no observable output in-process, so
    /// the only instrument that can see the call is a source one.
    func testTheRowReadsTheKindDerivedSlotsAndNotLiterals() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ZeusApp")
        let src = try String(contentsOf: root.appendingPathComponent("NodesView.swift"),
                             encoding: .utf8)
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let start = lines.firstIndex(where: { $0.contains("ForEach(Array(findHits.enumerated())") }) else {
            return XCTFail("VOID: the hit-row anchor moved — this leg measured nothing")
        }
        guard let end = lines[start...].firstIndex(where: { $0.contains(".padding(.top, 8)") }) else {
            return XCTFail("VOID: the closing anchor moved — the slice is unbounded")
        }
        let slice = lines[start..<end].joined(separator: "\n")

        XCTAssertTrue(slice.contains("icon: pair.element.icon"),
                      "the glyph is a literal again — every hit asserts FILE in a " +
                      "picture before a single string is read")
        XCTAssertTrue(slice.contains("label: pair.element.label"),
                      "the label slot is not kind-derived")
        XCTAssertTrue(slice.contains("Self.hitToast(pair.element)"),
                      "the toast is not routed through the kind switch")
        XCTAssertFalse(slice.contains("Recall.dirLabel("),
                       "`dirLabel` is called at the row — a record can reach it")
        // POS control: the slice contains something known present.
        XCTAssertTrue(slice.contains("Recall.scoreLabel("))
        // NEG control.
        XCTAssertFalse(slice.contains("zzzNoSuchSlot"))
    }

    /// THE APERTURE IS SELECTED BY THE ARM, like the write sentence.
    func testTheApertureFollowsTheConfigArm() throws {
        let url = try XCTUnwrap(URL(string: "http://10.0.0.5:8080"))
        let ep = GatewayConfig.Endpoint(url: url, token: "t")
        XCTAssertEqual(NodesView.aperture(for: .resolved(ep)), .gateway)
        XCTAssertEqual(NodesView.aperture(for: .local(.ready)), .embedded)
        XCTAssertEqual(NodesView.aperture(for: .absent), .embedded)
    }

}
