import XCTest
@testable import Zeus

/// The attach coherence arc: status precondition, coordinated read, coherence
/// post-condition.
///
/// The claim under test is scoped at the boundary — MATERIALISED-AND-COHERENT
/// against a non-adversarial, eventually-consistent provider, never "complete".
/// These legs can prove the app refuses a provider that contradicts ITSELF.
/// No leg here claims, or could claim, anything about a provider that
/// under-reports and short-reads in agreement.
final class AttachCoherenceTests: XCTestCase {

    // MARK: - (c) the writable red

    /// 🔴 THE LEG THE WHOLE SEAM SHAPE EXISTS TO MAKE WRITABLE.
    ///
    /// `declaredTotal` is a PARAMETER, so a short read is one call away. Had
    /// the seam read the size off the URL inline, the simulator would never
    /// produce a short read and THIS TEST COULD NOT BE WRITTEN — the guard
    /// would ship green and unfalsifiable, the tautology class that shipped
    /// once already this arc.
    func testAShortReadAgainstALargerDeclaredTotalIsRefused() {
        let verdict = AttachCoherence.coherence(declaredTotal: 4096, stagedCount: 512)
        XCTAssertFalse(verdict.isOK, "POS: 512 of a declared 4096 is a fragment and must refuse")
        guard case .refuse(let why) = verdict else {
            return XCTFail("VOID: expected a refusal carrying a sentence")
        }
        // The numbers are ON SCREEN. "STAGING FAILED" over a truncation cannot
        // be told from a broken app, and those send the operator elsewhere.
        XCTAssertTrue(why.contains("512"), "POS: the sentence names what arrived")
        XCTAssertTrue(why.contains("4096"), "POS: and what was declared")
        XCTAssertTrue(why.contains("NOTHING STAGED"),
                      "POS: refusal is stated, not implied")
        // Same bar as the empty guard: never claims receipt.
        XCTAssertFalse(why.uppercased().contains("RECEIVED"),
                       "NEG: a refusal must not describe the file as received")
    }

    /// The other side, or the leg above is satisfied by a seam that refuses
    /// everything — which would be a guard that cannot pass rather than one
    /// that cannot fail, equally useless and much louder.
    func testAFullReadAgainstItsDeclaredTotalIsAllowed() {
        XCTAssertTrue(AttachCoherence.coherence(declaredTotal: 4096, stagedCount: 4096).isOK,
                      "POS: exact agreement stages")
        XCTAssertTrue(AttachCoherence.coherence(declaredTotal: 4096, stagedCount: 8192).isOK,
                      "POS: over-read is incoherent but is not a fragment; `<` is deliberate")
    }

    /// A plain on-device file has NO declared total, and a guard that refused
    /// on a missing number would refuse the common case — every ordinary pick.
    func testAMissingDeclaredTotalIsAllowedRatherThanRefused() {
        XCTAssertTrue(AttachCoherence.coherence(declaredTotal: nil, stagedCount: 1).isOK,
                      "POS: no declared total means nothing to contradict")
        // VACUITY: the allow above must not be how the seam answers everything.
        XCTAssertNotEqual(AttachCoherence.coherence(declaredTotal: nil, stagedCount: 1),
                          AttachCoherence.coherence(declaredTotal: 4096, stagedCount: 512),
                          "VOID: the seam returns the same verdict for both, so it decides nothing")
    }

    // MARK: - (a) the status precondition

    /// Not `.current` is a placeholder whose bytes are elsewhere. Refusing
    /// before the read puts the whole partially-materialised class out of
    /// reach instead of detecting it afterwards.
    func testAnUndownloadedUbiquitousItemIsRefusedBeforeAnyRead() {
        let verdict = AttachCoherence.materialisation(
            downloadingStatus: URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue)
        XCTAssertFalse(verdict.isOK, "POS: a not-downloaded item must not be read")
        guard case .refuse(let why) = verdict else {
            return XCTFail("VOID: expected a refusal carrying a sentence")
        }
        // NAMES THE FIX, not just the state — a dead control with no next move
        // is the thing this arc keeps refusing to ship.
        XCTAssertTrue(why.contains("FILES"), "POS: the sentence names where to fix it")
        XCTAssertTrue(why.contains("NOT DOWNLOADED"), "POS: and what is wrong")
    }

    /// `.downloaded` is the LEGACY value and is NOT `.current` — it means bytes
    /// are local but possibly stale against the cloud copy. Treating it as
    /// materialised would readmit the exact incoherence the precondition
    /// exists to exclude.
    func testTheLegacyDownloadedStatusIsNotTreatedAsCurrent() {
        XCTAssertFalse(AttachCoherence.materialisation(
            downloadingStatus: URLUbiquitousItemDownloadingStatus.downloaded.rawValue).isOK,
            "POS: only `.current` is materialised-and-fresh")
        XCTAssertTrue(AttachCoherence.materialisation(
            downloadingStatus: URLUbiquitousItemDownloadingStatus.current.rawValue).isOK,
            "POS: and `.current` passes, or the precondition refuses everything")
    }

    /// A non-ubiquitous file has no downloading status at all. Most picks.
    func testANonUbiquitousFileHasNoStatusAndIsAllowed() {
        XCTAssertTrue(AttachCoherence.materialisation(downloadingStatus: nil).isOK,
                      "POS: a plain local file is not a ubiquitous item")
    }

    // MARK: - wiring: the legs above prove the seam, not that anything calls it

    /// 🔴 CORRECT-BUT-UNREACHED, third arrival this arc. Every leg above calls
    /// the seam directly and would stay green with `stage` never calling it —
    /// the file would be read uncoordinated, a fragment staged, and the whole
    /// guard dark. Only a wiring leg sees that.
    func testStageCallsBothCoherenceSeams() throws {
        let code = Self.codeOnly(try Self.rootViewSource())
        XCTAssertTrue(code.contains("AttachCoherence.materialisation(downloadingStatus:"),
                      "POS: the status precondition is wired into the pick path")
        XCTAssertTrue(code.contains("AttachCoherence.coherence(declaredTotal:"),
                      "POS: the coherence post-condition is wired into the pick path")
        // The declared total must reach the seam as an ARGUMENT. A call that
        // passed `nil` would satisfy the line above and check nothing.
        XCTAssertTrue(code.contains("declaredTotal: declaredTotal"),
                      "POS: the captured declared total is what is compared")
        XCTAssertTrue(code.contains("stagedCount: data.count"),
                      "POS: against the bytes actually read")
        XCTAssertGreaterThan(Self.count(of: "func stage(", in: code), 0,
                             "VOID: the corpus survived the strip")
    }

    /// (b) The read is COORDINATED, and the uncoordinated form is gone.
    ///
    /// Asserting the coordinator is present is not enough on its own: a build
    /// that coordinates and then reads the raw URL outside the block has both
    /// tokens and none of the barrier. So the raw form is asserted ABSENT.
    func testThePickReadsThroughAFileCoordinator() throws {
        let code = Self.codeOnly(try Self.rootViewSource())
        XCTAssertTrue(code.contains("NSFileCoordinator().coordinate(readingItemAt: url"),
                      "POS: the read is coordinated")
        XCTAssertTrue(code.contains("Data(contentsOf: coherent)"),
                      "POS: and reads the coordinator's URL, not the original")
        XCTAssertFalse(code.contains("Data(contentsOf: url)"),
                       "NEG: the uncoordinated read is gone, not merely shadowed")
        // The coordinator's own failure path never runs the accessor, so an
        // unchecked `readError` hands empty Data to the guards below and they
        // refuse for the wrong reason.
        XCTAssertTrue(code.contains("if readError != nil"),
                      "POS: the coordinator's own failure is checked")
    }

    /// 🔴 THE INLINE-REGRESSION CENSUS. The seam's power comes from
    /// `declaredTotal` being a parameter; the day someone reads it off a URL
    /// inside this file, the red for a short read stops being writable and the
    /// guard silently becomes a tautology. That regression has to put a URL
    /// read in this file, so the file's token census is the guard.
    func testTheCoherenceSeamCannotReadAFileItself() throws {
        let code = Self.codeOnly(try Self.source("AttachCoherence.swift"))
        XCTAssertFalse(code.contains("resourceValues"),
                       "NEG: reading the size here makes the short-read red unwritable")
        XCTAssertFalse(code.contains("URL("),
                       "NEG: the seam takes numbers, not files")
        XCTAssertFalse(code.contains("Data(contentsOf"),
                       "NEG: the seam does not read bytes")
        // POS CONTROL, same invocation. A stripper that ate the corpus would
        // satisfy all three NEGs above by measuring nothing.
        XCTAssertGreaterThan(Self.count(of: "static func coherence", in: code), 0,
                             "VOID: the seam source did not survive the strip")
        XCTAssertGreaterThan(Self.count(of: "declaredTotal", in: code), 0,
                             "VOID: the parameter the NEGs are about is absent")
    }

    /// The refusal reaches the operator through the SAME surface the empty
    /// guard uses — staged-but-incomplete shown as honestly as empty, rather
    /// than swallowed into a generic staging failure.
    func testAnIncoherentReadIsReportedAsAFailedStageNotASilentDrop() throws {
        let code = Self.codeOnly(try Self.rootViewSource())
        XCTAssertTrue(code.contains("if case .refuse(let why) = AttachCoherence.materialisation"),
                      "POS: the status refusal becomes a displayed reason")
        XCTAssertTrue(code.contains("return .failed(why)"),
                      "POS: carried to the operator, not logged and dropped")
        XCTAssertGreaterThan(Self.count(of: ".failed(why)", in: code), 1,
                             "POS: both refusals are displayed, not just the first")
    }

    // MARK: - helpers

    private static func count(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var n = 0
        var i = haystack.startIndex
        while let r = haystack.range(of: needle, range: i ..< haystack.endIndex) {
            n += 1
            i = r.upperBound
        }
        return n
    }

    /// Comments stripped. Fourth arrival of use-vs-mention in this arc: the doc
    /// comments in `AttachCoherence.swift` DISCUSS `resourceValues` by name in
    /// order to forbid it, so a raw census of that file reds on its own prose.
    private static func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slash = line.range(of: "//") else { return line }
                return line[line.startIndex ..< slash.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/\(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(text.count, 500, "VOID: \(name) did not load")
        return text
    }

    private static func rootViewSource() throws -> String {
        try source("RootView.swift")
    }
}
