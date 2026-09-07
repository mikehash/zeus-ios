import XCTest
@testable import Zeus

/// G0 legs: the LINK pill as a real control, the NODES gateway row in every
/// arm, the editor's read-back derivations, and the four preflight states.
///
/// APERTURE (stated once, top of file): a SwiftUI body is not observable
/// in-process, so these legs assert the DERIVATIONS (static, internal) and
/// the SOURCE TEXT (the census, by the tree's established `#filePath` grep
/// pattern) — not renderings. What is guarded here is the mapping and the
/// count; what is NOT guarded is the tap actually firing, which belongs to
/// the capture run on a full-Xcode box.
final class G0EditorTests: XCTestCase {

    // MARK: - Fixtures

    private func resolved() -> GatewayConfig {
        let e = GatewayConfig.Endpoint(
            url: URL(string: "https://zeus.example.com:8443")!,
            token: "t0")
        return .resolved(e)
    }

    private func local() -> GatewayConfig {
        .local(.ready)
    }

    private func malformed() -> GatewayConfig {
        .malformed(raw: "zeus dot local", reason: .notAURL)
    }

    /// THE FOUR ARMS. One fixture per arm so a later-added case fails the
    /// exhaustive switches at compile time, not this array at runtime.
    private var allArms: [GatewayConfig] {
        [.absent, local(), malformed(), resolved()]
    }

    // MARK: - The census: exactly one control in the grid

    /// Exactly one `action:` across the four `StatCell` call sites, and it
    /// is LINK's. The POS control: the plain `StatCell(` needle reads 4 in
    /// this file, so a wrong path VOIDs instead of falsely passing. The NEG
    /// needle is `action:` — counted on the SAME lines the census reads, not
    /// the whole file, because the editor's own body legitimately contains
    /// the word.
    func testExactlyOneStatCellIsAControl() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/HomeView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)

        // A call site may span lines (LINK's does — the action argument is
        // on its own line), so the census walks BLOCKS: from each
        // `StatCell(caption:` opener, the lines up to the one that closes
        // the call's parens. Comment-only lines are skipped, so a docstring
        // naming the needle cannot self-match.
        var blocks: [String] = []
        var i = src.startIndex
        let opener = "StatCell(caption:"
        while let r = src.range(of: opener, range: i..<src.endIndex) {
            var depth = 0
            var block = String(src[r.lowerBound..<src.endIndex])
            var end = r.lowerBound
            for ch in src[r.lowerBound..<src.endIndex] {
                block = String(src[r.lowerBound...end])
                if ch == "(" { depth += 1 }
                if ch == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                end = src.index(after: end)
            }
            blocks.append(block)
            i = src.index(after: end)
        }

        XCTAssertEqual(blocks.count, 4,
                       "POS control: the four grid call sites must all be here")
        XCTAssertTrue(blocks.contains { $0.contains("\"LINK\"") },
                      "POS control: the LINK call site is among them")

        let withAction = blocks.filter { $0.contains("action:") }
        XCTAssertEqual(withAction.count, 1,
                       "exactly one StatCell call site carries action: — found \(withAction.count)")
        XCTAssertTrue(withAction[0].contains("\"LINK\""),
                      "the one control is LINK, not another cell")
    }

    // MARK: - The trait: on the control arm, absent everywhere else

    /// The asymmetry at the source level: `.isButton` sits inside the
    /// `if let action` arm and NOWHERE else in this file — not the
    /// read-only `else` arm, not `cellBody`. Instrument: a brace-walk
    /// from each region opener to its matching close, comment-only
    /// lines skipped (the same census discipline — a docstring naming
    /// the needle cannot self-match). POS: the trait count inside the
    /// if-let block is >= 1 — if the walk were reading the wrong text,
    /// that POS would read 0 and VOID the leg. NEG: exactly 0 in the
    /// else arm and exactly 0 in cellBody. (a)∧(b) with the census
    /// above = trait on the one cell that passes `action:`, absent on
    /// the three that don't.
    func testIsButtonTraitLivesOnlyInTheActionArm() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/HomeView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)

        let needle = ".accessibilityAddTraits(.isButton)"

        // Brace-walk: from a region opener, to its matching `{`, to the
        // `}` that closes it. Returns nil when the opener is absent.
        func region(from opener: String) -> Substring? {
            guard let r = src.range(of: opener) else { return nil }
            guard let brace = src.range(of: "{", range: r.lowerBound..<src.endIndex) else { return nil }
            var depth = 0
            var end = brace.lowerBound
            for ch in src[brace.lowerBound..<src.endIndex] {
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                end = src.index(after: end)
            }
            return src[r.lowerBound..<end]
        }

        // Code-only line filter, as in the census.
        func traitCount(_ region: Substring?) -> Int {
            guard let region = region else { return -1 }  // -1 = opener absent: VOID, not pass
            return region.split(separator: "\n", omittingEmptySubsequences: true)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .reduce(0) { $0 + $1.components(separatedBy: needle).count - 1 }
        }

        let controlArm = region(from: "if let action = action {")
        let readOnlyArm = region(from: "} else {")
        let sharedBody = region(from: "private var cellBody: some View {")

        // POS control first: the walk must be able to SEE a trait where
        // one provably lives, else every 0 below is the walk's blindness.
        XCTAssertGreaterThanOrEqual(traitCount(controlArm), 1,
            "POS control: the if-let arm holds the trait — 0 here means the walk reads the wrong text, VOID not pass")

        XCTAssertEqual(traitCount(readOnlyArm), 0,
            "the read-only arm carries no isButton trait")
        XCTAssertEqual(traitCount(sharedBody), 0,
            "cellBody carries no isButton trait — the trait belongs to the wrapper, not the shared body")

        // Whole-file cardinality: exactly one, so a trait smuggled into a
        // fourth region (outside all three named) cannot hide.
        let wholeFile = src.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .reduce(0) { $0 + $1.components(separatedBy: needle).count - 1 }
        XCTAssertEqual(wholeFile, 1,
            "exactly one isButton in HomeView.swift — found \(wholeFile)")
    }

    // MARK: - The NODES row: present in EVERY arm, labelled by arm

    /// Four arms, four renderings of the same row derivation, asserted to
    /// differ only where the arm differs. An arm that hid the row would
    /// share a label with its neighbour — here, that means the two-arm
    /// distinctness assertion below fails rather than passing silently.
    func testGatewayRowExistsUnderEveryArmAndLabelsByArm() {
        let labels = allArms.map { NodesView.gatewayRowLabel(for: $0) }

        // The row EXISTS under every arm: a label is produced for each, and
        // an empty string is not a label.
        for (label, arm) in zip(labels, allArms) {
            XCTAssertFalse(label.isEmpty, "no label under \(arm)")
        }

        // The distinct set is exactly the ruled mapping: two arms share the
        // *use a remote gateway instead* label (deliberate), and the other
        // two are distinct from everything.
        XCTAssertEqual(Set(labels).count, 3,
                       "absent/local share one label; malformed and resolved are their own")
        XCTAssertEqual(labels[0], labels[1],
                       ".absent and .local share the remote-instead label (ruled)")
        XCTAssertTrue(labels[3].lowercased().contains("change"),
                      ".resolved offers change, not first-time setup: \(labels[3])")
        XCTAssertTrue(labels[2].lowercased().contains("fix"),
                      ".malformed offers repair: \(labels[2])")
    }

    /// The VALUE slot names the operand: the host when resolved, the raw
    /// broken string when malformed, nothing otherwise.
    func testGatewayRowValueNamesTheOperand() {
        XCTAssertEqual(NodesView.gatewayRowValue(for: resolved()), "zeus.example.com")
        XCTAssertEqual(NodesView.gatewayRowValue(for: malformed()), "zeus dot local")
        XCTAssertNil(NodesView.gatewayRowValue(for: .absent))
        XCTAssertNil(NodesView.gatewayRowValue(for: local()))
    }

    /// THE ROW ITSELF, guarded by TEXT: the gateway row is constructed in
    /// `mobileNode` — inside the shared `VStack(spacing: 0)` that every arm
    /// renders, OUTSIDE any per-arm conditional. The label mapping above
    /// could survive a view that only ever constructs the row in one arm;
    /// this leg is what fails when that happens. POS: the `icon: "globe"`
    /// needle reads 1 (the row's own site). NEG, same invocation: zero
    /// `if case` / `switch resolution` blocks between `mobileNode` and the
    /// row — the row's containing block is conditional-free.
    func testGatewayRowSiteIsUnconditionalInMobileNode() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/NodesView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)

        let mobileRange = src.range(of: "private var mobileNode")
        let rowRange = src.range(of: #"icon: "globe""#)
        let kitchenRange = src.range(of: "private var kitchenNode")

        let posMobile = mobileRange != nil
        let posRow = rowRange != nil
        let posKitchen = kitchenRange != nil
        XCTAssertTrue(posMobile && posRow && posKitchen,
                      "POS control: mobileNode, the gateway row, and kitchenNode all locate")

        let start = mobileRange!.lowerBound
        let rowStart = rowRange!.lowerBound
        let block = String(src[start..<rowStart])

        // The row precedes kitchenNode (i.e. it is in mobileNode's body).
        XCTAssertLessThan(rowStart, kitchenRange!.lowerBound,
                          "the gateway row lives inside mobileNode, not elsewhere")

        // UNCONDITIONAL: no arm-conditional construct between the start of
        // mobileNode and the row.
        for needle in ["if case", "switch resolution", "if resolution"] {
            XCTAssertFalse(block.contains(needle),
                           "the gateway row is gated by `\(needle)` — a conditional row hides the switch from the arm that needs it")
        }
    }

    // MARK: - The editor's read-back derivations

    /// Seeding: the field starts from the persisted/raw operand so the
    /// operator edits WHAT exists rather than retyping from scratch.
    func testSeedURLOpenedByArm() {
        XCTAssertEqual(GatewayEditorSheet.seedURL(for: resolved()),
                       "https://zeus.example.com:8443")
        XCTAssertEqual(GatewayEditorSheet.seedURL(for: malformed()),
                       "zeus dot local")
        XCTAssertEqual(GatewayEditorSheet.seedURL(for: .absent), "")
        XCTAssertEqual(GatewayEditorSheet.seedURL(for: local()), "")
    }

    /// The Keychain account is the HOST — one token per host, so switching
    /// hosts switches credentials rather than replaying one token.
    func testHostKeyIsTheHostOnly() {
        XCTAssertEqual(GatewayEditorSheet.hostKey(for: resolved()),
                       "zeus.example.com")
        // A malformed operand with a recognisable host still keys by it;
        // one without yields empty, which the store never reads as a key.
        XCTAssertEqual(GatewayEditorSheet.hostKey(for: malformed()), "")
    }

    // MARK: - The four preflight states

    /// 2xx with a token ⇒ TOKEN OK. The happy path is a state like any
    /// other, not the absence of one.
    func testPreflightTwoHundredWithTokenIsTokenOK() {
        XCTAssertEqual(
            GatewayEditorSheet.preflightState(httpStatus: 200, hadToken: true,
                                              transportFailed: false),
            .tokenOK)
    }

    /// 401 WITH a token ⇒ TOKEN REJECTED — the credential was supplied and
    /// the server refused it.
    func testPreflightFourOhOneWithTokenIsRejected() {
        XCTAssertEqual(
            GatewayEditorSheet.preflightState(httpStatus: 401, hadToken: true,
                                              transportFailed: false),
            .tokenRejected)
    }

    /// 401 WITHOUT a token ⇒ NO TOKEN — API BLOCKED. The gateway is up and
    /// answering; the app has nothing to present.
    func testPreflightFourOhOneWithoutTokenIsBlocked() {
        XCTAssertEqual(
            GatewayEditorSheet.preflightState(httpStatus: 401, hadToken: false,
                                              transportFailed: false),
            .noTokenBlocked)
    }

    /// Transport failure ⇒ GATEWAY UNREACHABLE, NEVER folded into TOKEN
    /// REJECTED — a dead host and a wrong token are different subjects and
    /// the operator fixes them differently. This leg holds that boundary
    /// even when a token is present, which is exactly the arm a naive
    /// implementation collapses first.
    func testPreflightTransportFailureIsUnreachableEvenWithAToken() {
        XCTAssertEqual(
            GatewayEditorSheet.preflightState(httpStatus: nil, hadToken: true,
                                              transportFailed: true),
            .gatewayUnreachable)
        XCTAssertNotEqual(
            GatewayEditorSheet.preflightState(httpStatus: nil, hadToken: true,
                                              transportFailed: true),
            .tokenRejected)
    }

    // MARK: - Token store: presence, replace, remove

    func testTokenStorePresenceReplaceAndRemove() {
        let store = InMemoryTokenStore()
        XCTAssertFalse(store.hasToken(host: "zeus.example.com"))
        store.save(token: "a", host: "zeus.example.com")
        XCTAssertTrue(store.hasToken(host: "zeus.example.com"))
        // REPLACE, not duplicate: re-saving the same host is an upsert.
        store.save(token: "b", host: "zeus.example.com")
        XCTAssertTrue(store.hasToken(host: "zeus.example.com"))
        // Per-host isolation: one host's token is not another's.
        XCTAssertFalse(store.hasToken(host: "other.example.com"))
        store.removeToken(host: "zeus.example.com")
        XCTAssertFalse(store.hasToken(host: "zeus.example.com"))
    }
}
