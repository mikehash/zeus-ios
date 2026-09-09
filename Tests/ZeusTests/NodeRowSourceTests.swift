import XCTest
@testable import Zeus

/// (h) — every value on the phone row names its source or goes.
///
/// Three literals were enumerated (`ACTIVE`, `zeus-core 0.9`, `LIVE-LINK`) and
/// a fourth was riding with the third: the tap raised
/// `MNEMOSYNE CONSISTENT — NO DELTA`, a RESULT REPORTED FOR A CHECK THAT NEVER
/// RAN. That is a different and worse class than a stale label — a stale label
/// is a fact that expired, a fabricated result is a fact that never was.
///
/// APERTURE, STATED. The badge and subtitle legs below are SOURCE CENSUSES on
/// `NodesView.swift`, not renders: `mobileNode` is a `private var` inside a
/// view body and is not reachable from the test target. What IS reachable —
/// and is asserted behaviourally — is every pure function those renders call.
/// So the shape is: the pure function is proved over its whole domain, and the
/// census proves the view calls it rather than a literal. Neither half alone
/// is the claim.
final class NodeRowSourceTests: XCTestCase {

    private func nodesViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/ZeusApp/NodesView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Code lines only.
    ///
    /// The retired strings survive AS PROSE in this file's own doc comments
    /// and in `NodesView`'s explanation of the retirement — a whole-file needle
    /// would hit my own account of the deletion and read as a regression. This
    /// is the `All systems nominal` fault, which has now cost a run twice, so
    /// the filter carries its own control below.
    private func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("//") && !t.hasPrefix("///") && !t.hasPrefix("*")
            }
    }

    // MARK: - the filter itself

    /// Without this, every absence below is a statement about `codeLines`
    /// rather than about the tree: a filter that returned nothing at all would
    /// pass all four censuses.
    func testTheCodeLineFilterKeepsCode() throws {
        let code = codeLines(try nodesViewSource()).joined(separator: "\n")
        XCTAssertTrue(code.contains("private var mobileNode"),
                      "the code-line filter dropped a declaration — no absence " +
                      "verdict in this file is about NodesView.swift")
        XCTAssertFalse(code.contains("(h) — WAS `LIVE-LINK`"),
                       "the code-line filter kept a doc comment — the retired " +
                       "strings live in prose and would be counted as code")
    }

    // MARK: - ACTIVE

    /// The badge is the composed readiness, not a literal.
    ///
    /// POS in the same read: the derivation must be PRESENT, not merely the
    /// literal absent. A commit that deleted the badge entirely would satisfy
    /// an absence-only leg.
    func testThePhoneBadgeReadsTheComposedReadiness() throws {
        let code = codeLines(try nodesViewSource()).joined(separator: "\n")
        XCTAssertFalse(code.contains("\"ACTIVE\""),
                       "the phone row renders a hardcoded ACTIVE again — it is " +
                       "green over an unarmed core, which is the defect " +
                       "ProviderArming.swift's header was written for")
        XCTAssertTrue(code.contains("ReadinessBadge.forState"),
                      "POS: the badge no longer reads the shared derivation — " +
                      "the HOME tile, the SESSION pill and this row must not " +
                      "be able to disagree about whether the agent can answer")
    }

    /// `UNARMED` overrides the phase, so the row is a function of readiness
    /// alone — asserted on the derivation itself, over BOTH arms, because a
    /// one-armed leg cannot tell a working composition from a constant.
    func testTheBadgeIsUnarmedExactlyWhenThereIsNoRoute() {
        XCTAssertEqual(ReadinessBadge.forState(.ambient, disarmReason: nil).text,
                       "NOMINAL")
        XCTAssertEqual(
            ReadinessBadge.forState(.ambient, disarmReason: "no provider").text,
            "UNARMED")
        XCTAssertNotEqual(
            ReadinessBadge.forState(.ambient, disarmReason: nil).tint,
            ReadinessBadge.forState(.ambient, disarmReason: "x").tint,
            "vacuity: the two arms must be visually distinguishable, or the " +
            "badge carries no information for a sighted operator")
    }

    // MARK: - zeus-core 0.9

    func testTheSubtitleNoLongerClaimsAVersion() throws {
        let code = codeLines(try nodesViewSource()).joined(separator: "\n")
        XCTAssertFalse(code.contains("zeus-core 0.9"),
                       "`0.9` matched nothing: the bridge exports no version " +
                       "and the crate is 0.1.0 — it was unfalsifiable, not stale")
        XCTAssertTrue(code.contains("CoreProvenance.nodeSubtitle"),
                      "POS: the subtitle no longer reads the bundled manifest")
    }

    /// The pin is extracted from the Cargo fragment the build script writes,
    /// NOT from the whole line.
    func testTheSubtitleRendersTheDepPinWhenTheManifestShipped() {
        let text = """
        built:      2026-09-08T17:56:09Z
        dep-pin:    rev = "2bfc08aa11148012fc5aa5db92fea6a88c11d599"
        crate-tree: faf1983552f38838b017f464330cf62d521e2793
        """
        XCTAssertEqual(CoreProvenance.value("dep-pin", in: text),
                       "rev = \"2bfc08aa11148012fc5aa5db92fea6a88c11d599\"")
        XCTAssertEqual(
            CoreProvenance.shortSHA(from: CoreProvenance.value("dep-pin", in: text)!),
            "2bfc08aa")
        // The pin and the tree are DIFFERENT shas in this fixture, so a
        // reader that grabbed the wrong line cannot pass by coincidence.
        XCTAssertNotEqual(CoreProvenance.value("dep-pin", in: text),
                          CoreProvenance.value("crate-tree", in: text))
    }

    /// A duplicated key VOIDS rather than picking the first.
    func testAnAmbiguousManifestYieldsNothing() {
        let text = """
        dep-pin:    rev = "2bfc08aa11148012fc5aa5db92fea6a88c11d599"
        dep-pin:    rev = "1111111111111111111111111111111111111111"
        """
        XCTAssertNil(CoreProvenance.value("dep-pin", in: text),
                     "two provenances and no way to choose — a guess here " +
                     "renders one build's sha for another build's binary")
    }

    /// Malformed or absent → the row abstains, and what it falls back to is
    /// TRUE rather than a literal.
    func testAMalformedPinAbstainsRatherThanRenderingAFragment() {
        XCTAssertNil(CoreProvenance.shortSHA(from: "rev = \"2bfc08a\""),
                     "a short run of hex is not a sha — rendering it would " +
                     "put `2bfc08a` in front of an operator as a version")
        XCTAssertNil(CoreProvenance.shortSHA(from: "not a sha at all"))
    }

    /// The manifest actually SHIPS in the built app — gate two, measured.
    ///
    /// The value existing in `Frameworks/` is what the repo-root reader
    /// already proved. This leg is the other half: a phone has no repo, so a
    /// row rendering provenance is only possible if the resource is in the
    /// bundle. Without this, `nodeSubtitle` would silently and permanently
    /// return the abstention arm on device and the leg above would still pass.
    func testTheManifestIsBundledWithTheApp() throws {
        // …/Zeus.app/PlugIns/ZeusTests.xctest -> …/Zeus.app. TWO levels, and
        // my first cut dropped one — the control below caught it and the VOID
        // underneath then read as "no manifest shipped" when it meant "that
        // was not the app". Same resolution as `BundleResourceTests`.
        let testBundle = Bundle(for: NodeRowSourceTests.self)
        let hostURL = testBundle.bundleURL
            .deletingLastPathComponent()   // PlugIns
            .deletingLastPathComponent()   // Zeus.app
        guard let host = Bundle(url: hostURL) else {
            throw XCTSkip("host app bundle not resolvable at \(hostURL.path)")
        }
        XCTAssertEqual(host.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                       "Zeus",
                       "resolved bundle is not the app — the verdict below is " +
                       "not about what shipped")
        guard let text = CoreProvenance.manifestText(in: host) else {
            return XCTFail("VOID: no zeus-build-manifest.txt in the built app " +
                           "— the phone row can never render provenance, and " +
                           "nodeSubtitle() abstains forever on device")
        }
        XCTAssertNotNil(CoreProvenance.value("dep-pin", in: text),
                        "the bundled manifest carries no dep-pin line")
        XCTAssertTrue(CoreProvenance.nodeSubtitle(in: host).hasPrefix("core "),
                      "the bundled manifest is present but the subtitle still " +
                      "abstains — the extractor and the producer disagree")
    }

    // MARK: - LIVE-LINK and the fabricated toast

    func testTheMnemosyneRowNoLongerRendersALiteral() throws {
        let code = codeLines(try nodesViewSource()).joined(separator: "\n")
        XCTAssertFalse(code.contains("LIVE-LINK"))
        XCTAssertFalse(code.contains("MNEMOSYNE CONSISTENT"),
                       "a result reported for a check that never ran is a " +
                       "fabrication, not a label")
        XCTAssertTrue(code.contains("core?.indexSize()"),
                      "POS: the row and the tap must READ the core, not a string")
    }

    /// Three states, and the third is the point.
    ///
    /// `nil` (no core to ask) is NOT folded into zero (a core that answered
    /// nothing). The bridge's own docstring calls `index_size` "a vacuity
    /// probe, not a statistic" — its entire job is separating an empty index
    /// from a probe that did not run, and collapsing them here would throw
    /// away the one distinction the export exists for.
    func testTheMnemosyneValueSeparatesEmptyFromAbsent() {
        XCTAssertEqual(NodesView.mnemosyneValue(indexSize: 12), "12 FILES INDEXED")
        XCTAssertEqual(NodesView.mnemosyneValue(indexSize: 0), "INDEX EMPTY")
        XCTAssertEqual(NodesView.mnemosyneValue(indexSize: nil), "NO CORE")
        XCTAssertNotEqual(NodesView.mnemosyneValue(indexSize: 0),
                          NodesView.mnemosyneValue(indexSize: nil),
                          "vacuity: an empty index and an unavailable core " +
                          "must not render the same words")
    }

    /// The tap reports the reading it took, and the three arms differ.
    func testTheTapReportsWhatItFound() {
        XCTAssertEqual(NodesView.mnemosyneToast(indexSize: 7),
                       "MNEMOSYNE — 7 FILES INDEXED")
        XCTAssertEqual(NodesView.mnemosyneToast(indexSize: 0),
                       "MNEMOSYNE — INDEX EMPTY")
        XCTAssertEqual(NodesView.mnemosyneToast(indexSize: nil),
                       "MNEMOSYNE — NO CORE ON THIS DEVICE")
        XCTAssertEqual(Set([NodesView.mnemosyneToast(indexSize: 7),
                            NodesView.mnemosyneToast(indexSize: 0),
                            NodesView.mnemosyneToast(indexSize: nil)]).count, 3)
    }

    /// The row and the toast are the same reading.
    ///
    /// Two accessors over the same input can disagree — the row saying
    /// `INDEX EMPTY` while the tap says a count is the defect this whole item
    /// is about, one layer in.
    func testTheRowAndTheTapAgreeOnTheSameReading() {
        for n: UInt32? in [nil, 0, 3, 900] {
            let row = NodesView.mnemosyneValue(indexSize: n)
            let toast = NodesView.mnemosyneToast(indexSize: n)
            XCTAssertTrue(toast.contains(row),
                          "row `\(row)` and toast `\(toast)` are different " +
                          "readings of the same number")
        }
    }

    // MARK: - the handle is received, not built

    /// `NodesView` must not construct a core.
    ///
    /// A handle built in this view would be a SECOND core over the same
    /// workspace directory — the `InMemoryProviderKeyStore` fault one
    /// subsystem over, where two instances agreed only by accident of a shared
    /// backend. `RootView` hands down the process's one core.
    func testTheViewReceivesTheCoreAndDoesNotBuildOne() throws {
        let code = codeLines(try nodesViewSource()).joined(separator: "\n")
        XCTAssertFalse(code.contains("ZeusCore.`init`"))
        XCTAssertFalse(code.contains("EmbeddedCore.shared"),
                       "the pane resolved its own core — it must arrive as a " +
                       "parameter from RootView, which owns the one handle")
        XCTAssertTrue(code.contains("var core: ZeusCoreProtocol?"),
                      "POS: the parameter is gone, so the absences above are " +
                      "satisfied by a view that reads no core at all")
    }
}
