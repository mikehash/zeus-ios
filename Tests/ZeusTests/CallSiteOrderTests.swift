import XCTest
@testable import Zeus

/// THE RELATION LEG.
///
/// Three builds died on one defect: a call site passing a memberwise
/// initialiser's arguments in an order the declaration does not have
/// (`RootView:255`, then `:266`, then `:308` — `HomeView`, `HomeView` again,
/// `NodesView`). Each was found by the compiler and by nothing else.
///
/// The reason nothing else found it is a property of the INSTRUMENT, not of
/// the reviewers: every needle we had was a PRESENCE census (`SecureField`
/// reads 1, `URLSession` reads 6, `: GatewayConfig = ` reads 0). Argument
/// order is not a presence property. It is a RELATION between two coordinates
/// — the index of a label in the declaration and the index of the same label
/// in the call — and a grep for either coordinate alone is green in both the
/// correct and the inverted world.
///
/// So this leg reads both coordinates and asserts the map between them is
/// monotone. It fails a test before it fails a build.
///
/// CONTROLS. A monotonicity assertion over an empty sequence is satisfied by
/// silence — the first draft of this file printed `MONOTONE ✅ []` for all
/// three subjects because the label regex resolved nothing, and it printed it
/// green against the *inverted* call. Every leg below therefore carries a
/// cardinality control on BOTH halves (declaration non-empty, call non-empty)
/// and an unknown-label control, and VOIDs rather than passes when a walk
/// reads nothing.
final class CallSiteOrderTests: XCTestCase {

    // MARK: - substrate

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
        return try String(contentsOf: root.appendingPathComponent("Sources/ZeusApp/\(name)"),
                          encoding: .utf8)
    }

    private func codeLines(_ src: String) -> [String] {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// Stored properties of `struct <name>`, in declaration order, stopping at
    /// `var body` — the memberwise initialiser's parameter order is exactly
    /// this sequence, which is the whole reason the defect class exists.
    ///
    /// `private` members are excluded: they are not passable at a call site.
    /// Computed properties are excluded by the `{`-on-the-line test.
    private func declaredLabels(of name: String, in src: String) -> [String] {
        var out: [String] = []
        var inside = false
        for line in codeLines(src) {
            if !inside {
                if line.contains("struct \(name)") { inside = true }
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("var body") { break }
            if t.contains("private") { continue }
            guard let m = t.range(of: #"^(@\w+(\([^)]*\))?\s+)*(let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:"#,
                                  options: .regularExpression) else { continue }
            let decl = String(t[m])
            if decl.contains("{") { continue }
            guard let nameRange = decl.range(of: #"[A-Za-z_][A-Za-z0-9_]*\s*:$"#,
                                             options: .regularExpression) else { continue }
            out.append(String(decl[nameRange]).replacingOccurrences(of: ":", with: "")
                        .trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    /// Argument labels of the first `<name>(` call in `src`, in call order.
    ///
    /// Depth-aware on BOTH parens and braces: a trailing-closure argument
    /// (`onOpenGatewayEditor: { config in … }`) contains assignments and could
    /// contain colons, and a nested call (`link.state`) must not contribute a
    /// label. Only `label:` at paren-depth 1 and brace-depth 0 counts.
    private func callLabels(to name: String, in src: String) -> [String] {
        let text = codeLines(src).joined(separator: "\n")
        guard let start = text.range(of: "\(name)(") else { return [] }
        var labels: [String] = []
        var paren = 0
        var brace = 0
        var token = ""
        var i = text.index(before: start.upperBound)   // the '('
        while i < text.endIndex {
            let c = text[i]
            switch c {
            case "(": paren += 1; token = ""
            case ")":
                paren -= 1
                if paren == 0 { return labels }
                token = ""
            case "{": brace += 1; token = ""
            case "}": brace -= 1; token = ""
            case ",": if paren == 1 && brace == 0 { token = "" }
            case ":":
                if paren == 1 && brace == 0 {
                    let cand = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cand.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil {
                        labels.append(cand)
                    }
                }
                token = ""
            default: token.append(c)
            }
            i = text.index(after: i)
        }
        return labels
    }

    // MARK: - the leg

    private func assertMonotone(_ view: String,
                                declaredIn declFile: String,
                                calledIn callFile: String,
                                minimumArity: Int,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let decl = declaredLabels(of: view, in: try source(declFile))
        let call = callLabels(to: view, in: try source(callFile))

        // CONTROL A — the declaration walk read something.
        XCTAssertGreaterThanOrEqual(decl.count, minimumArity,
            "\(view): declaration walk read \(decl.count) stored properties in \(declFile) — VOID, the walk reads the wrong text, not a passing order check",
            file: file, line: line)

        // CONTROL B — the call walk read something.
        XCTAssertGreaterThanOrEqual(call.count, minimumArity,
            "\(view): call walk read \(call.count) labels in \(callFile) — VOID, an empty sequence satisfies monotonicity by silence",
            file: file, line: line)

        // CONTROL C — every label passed is a label declared. An unknown label
        // means the two walks are reading different subjects, in which case the
        // index map below is meaningless rather than wrong.
        let unknown = call.filter { !decl.contains($0) }
        XCTAssertEqual(unknown, [],
            "\(view): call passes labels absent from the declaration \(unknown) — the walks disagree on the subject",
            file: file, line: line)

        // THE RELATION.
        let idx = call.compactMap { decl.firstIndex(of: $0) }
        XCTAssertEqual(idx.count, call.count,
            "\(view): \(call.count - idx.count) labels failed to resolve to a declared index — VOID",
            file: file, line: line)
        XCTAssertEqual(idx, idx.sorted(),
            "\(view): call-site argument order \(idx) is not monotone against the declaration \(decl) — the memberwise initialiser is order-fixed, this is a compile error waiting at \(callFile)",
            file: file, line: line)
    }

    func testHomeViewCallSiteMatchesDeclaredOrder() throws {
        try assertMonotone("HomeView", declaredIn: "HomeView.swift",
                           calledIn: "RootView.swift", minimumArity: 7)
    }

    /// Arity 5 → 4 at (d): `link:` was retired with the kitchen block, whose
    /// `nodeOnline` reads were its only consumers. The floor moves with the
    /// declaration deliberately — a floor left at 5 would go red on a correct
    /// tree, and a floor of 0 would pass on an empty one. The not-a-constant
    /// control below is what keeps 4 meaningful: it asserts the three views'
    /// label lists are not all the same list.
    func testNodesViewCallSiteMatchesDeclaredOrder() throws {
        try assertMonotone("NodesView", declaredIn: "NodesView.swift",
                           calledIn: "RootView.swift", minimumArity: 4)
    }

    /// SETTINGS is the fourth subject, and it is the one the moved arity
    /// lands on. Four labels DEPARTED `NodesView` at this commit — `routes`,
    /// `onOpenRoutes`, `commissionedProvider`, `onOpenGatewayEditor` — and a
    /// floor left only on NODES would be green on a tree where all four
    /// evaporated instead of moving. The floor of 7 is the departed four plus
    /// the three SETTINGS declares of its own (`onToast`, `resolution`,
    /// `onToggleNarration` … `narrationOn` makes eight; 7 is the honest floor,
    /// not the count).
    func testSettingsViewCallSiteMatchesDeclaredOrder() throws {
        try assertMonotone("SettingsView", declaredIn: "SettingsView.swift",
                           calledIn: "RootView.swift", minimumArity: 7)
    }

    /// THE MOVE, ASSERTED AS A MOVE. The four departed labels are absent from
    /// the NODES call site AND present on the SETTINGS one, read in a single
    /// invocation so a walk that resolved nothing fails the present half
    /// rather than passing the absent half by silence.
    func testTheFourDepartedLabelsLandedOnSettings() throws {
        let nodes = callLabels(to: "NodesView", in: try source("RootView.swift"))
        let settings = callLabels(to: "SettingsView", in: try source("RootView.swift"))
        let departed = ["routes", "onOpenRoutes", "commissionedProvider",
                        "onOpenGatewayEditor"]
        for label in departed {
            XCTAssertFalse(nodes.contains(label),
                           "`\(label)` is still passed to NodesView — the row moved but the operand did not")
            XCTAssertTrue(settings.contains(label),
                          "`\(label)` reached neither view — the arity evaporated instead of moving")
        }
        // POS control, same invocation: a label that legitimately STAYED is
        // still on NODES, so the absences above are a property of the four
        // and not of a walk that read an empty call site.
        XCTAssertTrue(nodes.contains("resolution"),
                      "VOID: the NodesView call walk read nothing — every absence above is vacuous")
    }

    /// (d) NEG, SECOND SUBJECT. `onOpenGatewayEditor` outlived its only body
    /// call site when the gateway row left: the declaration kept a closure
    /// nothing invoked, which is the `link:` hole exactly — invisible to the
    /// monotone leg, because that leg only ever walks labels the CALL passes,
    /// and a caller happily passing a dead operand is monotone.
    func testNodesViewNoLongerDeclaresTheGatewayEditorOperand() throws {
        let decl = try source("NodesView.swift")
        let declCode = decl.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
        XCTAssertFalse(declCode.contains("var onOpenGatewayEditor"),
                       "NodesView still declares `onOpenGatewayEditor` with no body call site")
        XCTAssertFalse(declCode.contains("gatewayRowLabel(for:"),
                       "the private row computeds outlived the row they fed")
        // POS control: the needle is alive on the view that DID take the row.
        let settings = try source("SettingsView.swift")
        XCTAssertTrue(settings.contains("var onOpenGatewayEditor"),
                      "VOID: the operand is on neither view — it was deleted, not moved")
        // The pure functions stay put: `G0EditorTests` calls them as
        // `NodesView.gatewayRowLabel`, and moving the type would move four
        // green legs onto a symbol nothing renders.
        XCTAssertTrue(decl.contains("static func gatewayRowLabel"),
                      "the arm-label functions left NodesView — G0EditorTests' subject moved under it")
    }

    /// The one BEHAVIOURAL line in the move: the catalogue load was a `.task`
    /// on NODES and is now a `.task` on SETTINGS. A row rendered on a pane
    /// that never loads the store shows an empty catalogue forever.
    func testTheRouteCatalogueLoadsWhereTheRowNowLives() throws {
        XCTAssertFalse(try source("NodesView.swift").contains("routes.load()"),
                       "NODES still loads a catalogue for a row it no longer renders")
        XCTAssertTrue(try source("SettingsView.swift").contains(".task { await routes.load() }"),
                      "the ROUTE row moved without its loader — the picker opens empty")
    }

    /// (d) NEG: `link` is gone from BOTH sides. An unused parameter left on
    /// the declaration is invisible to the monotone leg — it only ever walks
    /// the labels the CALL passes — so the arity floor alone cannot see a
    /// declaration that kept a dead operand. POS control in the same
    /// invocation: `routes` is present on both sides.
    func testNodesViewNoLongerDeclaresOrPassesLink() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let decl = try String(contentsOf: root.appendingPathComponent("Sources/ZeusApp/NodesView.swift"), encoding: .utf8)
        let call = try String(contentsOf: root.appendingPathComponent("Sources/ZeusApp/RootView.swift"), encoding: .utf8)

        let declCode = decl.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }.joined(separator: "\n")
        // Re-anchored at the SETTINGS arc: `routes` MOVED to SettingsView, so
        // reading it here asserted the opposite of what it was written for.
        // `resolution` is the label that legitimately stayed, and it is the
        // live POS needle on both sides.
        XCTAssertTrue(declCode.contains("var resolution: GatewayConfig.Resolution"),
                      "POS control: the declaration still carries `resolution` — needle alive")
        XCTAssertFalse(declCode.contains("let link: LinkState"),
                       "NodesView still declares `link` — an unused parameter is a hole a future caller fills wrongly")

        guard let siteRange = call.range(of: "NodesView(") else {
            return XCTFail("VOID: no NodesView call site in RootView.swift")
        }
        let site = String(call[siteRange.lowerBound...].prefix(400))
        XCTAssertTrue(site.contains("resolution:"), "POS control: the call site passes `resolution`")
        XCTAssertFalse(site.contains("link:"),
                       "RootView still passes `link:` to NodesView")
    }

    func testGatewayEditorSheetCallSiteMatchesDeclaredOrder() throws {
        try assertMonotone("GatewayEditorSheet", declaredIn: "GatewayEditor.swift",
                           calledIn: "RootView.swift", minimumArity: 5)
    }

    /// VACUITY GUARD on the three legs above. If the walks were reading a
    /// constant — the same list for every subject — the monotone assertion
    /// would hold for all three and prove nothing about any of them. The three
    /// declarations must actually differ.
    func testTheThreeSubjectsAreActuallyDistinct() throws {
        let home = declaredLabels(of: "HomeView", in: try source("HomeView.swift"))
        let nodes = declaredLabels(of: "NodesView", in: try source("NodesView.swift"))
        let editor = declaredLabels(of: "GatewayEditorSheet", in: try source("GatewayEditor.swift"))
        XCTAssertNotEqual(home, nodes, "two subjects resolved to the same label list — the walk is reading a constant")
        XCTAssertNotEqual(nodes, editor, "two subjects resolved to the same label list — the walk is reading a constant")
        XCTAssertNotEqual(home, editor, "two subjects resolved to the same label list — the walk is reading a constant")

        // The fourth subject joins the control: SETTINGS took four of NODES's
        // labels, so "distinct" is a claim worth re-asserting on the pair that
        // now shares the most.
        let settings = declaredLabels(of: "SettingsView", in: try source("SettingsView.swift"))
        XCTAssertNotEqual(settings, nodes, "SETTINGS and NODES resolved to the same label list")
        XCTAssertNotEqual(settings, home, "SETTINGS and HOME resolved to the same label list")
        XCTAssertNotEqual(settings, editor, "SETTINGS and the editor resolved to the same label list")
    }

    /// THE MUTATION, RESIDENT. The three legs assert a property of the tree;
    /// this asserts the DETECTOR fires on the inverted world, so a future
    /// regression of the walk itself (a label regex that resolves nothing, the
    /// exact way this file's first draft failed) cannot leave three silent
    /// green legs behind. Synthetic sources — no production text is mutated.
    func testTheDetectorFailsOnAnInvertedCall() {
        let decl = """
        struct Subject: View {
            let alpha: String
            var beta: (String) -> Void
            let gamma: Int
            var body: some View { EmptyView() }
        }
        """
        let good = "Subject(alpha: a, beta: { _ in }, gamma: 3)"
        let bad  = "Subject(alpha: a, gamma: 3, beta: { _ in })"

        let labels = declaredLabels(of: "Subject", in: decl)
        XCTAssertEqual(labels, ["alpha", "beta", "gamma"],
                       "the declaration walk cannot read a three-property struct — every leg above is VOID")

        let goodIdx = callLabels(to: "Subject", in: good).compactMap { labels.firstIndex(of: $0) }
        XCTAssertEqual(goodIdx, [0, 1, 2], "the call walk cannot read a correct call")
        XCTAssertEqual(goodIdx, goodIdx.sorted(), "the detector rejects a correct call")

        let badIdx = callLabels(to: "Subject", in: bad).compactMap { labels.firstIndex(of: $0) }
        XCTAssertEqual(badIdx, [0, 2, 1], "the call walk cannot read an inverted call")
        XCTAssertNotEqual(badIdx, badIdx.sorted(),
                          "THE DETECTOR DOES NOT FIRE — the three legs above are decoration")
    }
}
