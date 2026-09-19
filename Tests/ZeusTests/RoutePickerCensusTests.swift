import XCTest
@testable import Zeus

/// THE EXTRACTION'S OWN GUARD.
///
/// Arc B made the route picker reachable from NODES. There were two shapes
/// available — paste a second picker into `NodesView.swift`, or move the one
/// that exists — and the reason it had to be the second is measurable:
///
/// EVERY census that keeps this picker honest was FILE-SCOPED on
/// `Commissioning.swift`. The ban on provider literals, "the model field is
/// not gated on the catalogue" (the Ollama-only defect in its newest costume),
/// "exactly one key-write site", "the debounce cancels the in-flight poll".
/// A pasted copy inherits NONE of them: it could hardcode a vendor id, gate
/// the free-text field on `.listed`, and open one HTTP request per keystroke,
/// with all of them still green.
///
/// So the code moved and the censuses moved with it. THIS FILE ASSERTS THAT
/// THE MOVE HAPPENED — that the guards read the extracted component and are
/// not still pointed at the file the code left. Without it, "extract rather
/// than duplicate" is a claim in a commit message.
final class RoutePickerCensusTests: XCTestCase {

    // MARK: - The component exists, and the picker is no longer in the old file

    /// VACUITY GATE for everything below: if the extraction did not happen,
    /// every "the census reads `RoutePicker.swift`" leg is asserting about a
    /// file that does not exist, and a throw is a clearer failure than a green
    /// count over an empty string.
    func testTheExtractedComponentExistsAndOwnsThePickerState() throws {
        let picker = try source("RoutePicker.swift")
        XCTAssertTrue(picker.contains("struct RoutePicker: View"),
                      "VOID: the extracted component is not there")
        // Named individually rather than counted: a count cannot say WHICH
        // field failed to move, and a half-moved picker compiles.
        for field in ["providerPick", "modelText", "modelPoll", "pollTask",
                      "keyText", "baseURLText", "providerRows", "providerQuery"] {
            XCTAssertTrue(picker.contains("@State private var \(field)"),
                          "`\(field)` must live on the extracted component")
        }
        // And the old home no longer declares them — otherwise the code was
        // COPIED, and two divergent pickers is strictly worse than one.
        let old = try source("Commissioning.swift")
        for field in ["providerPick", "modelText", "keyText", "baseURLText",
                      "providerRows", "providerQuery"] {
            XCTAssertFalse(old.contains("@State private var \(field)"),
                           "`\(field)` stayed behind: the picker was copied, not moved")
        }
    }

    /// The picker censuses now READ the extracted component.
    ///
    /// Structural on purpose: a behavioural test cannot see which FILE a
    /// source-census opens, and every one of these is a source-census.
    func testThePickerCensusesAnchorOnTheExtractedComponent() throws {
        let expectations: [(file: String, needle: String)] = [
            ("ModelPollTests.swift",        "Sources/ZeusApp/RoutePicker.swift"),
            ("ProviderKeyStoreTests.swift", "source(\"RoutePicker.swift\")"),
            ("ProviderCatalogTests.swift",  "source(\"RoutePicker.swift\")"),
            ("PickSeamTests.swift",         "sourceFile(\"RoutePicker.swift\")"),
            ("CommissionStoreTests.swift",  "\"RoutePicker.swift\""),
        ]
        for e in expectations {
            let src = try testSource(e.file)
            XCTAssertFalse(src.isEmpty, "VOID: \(e.file) read as empty")
            XCTAssertTrue(src.contains(e.needle),
                          "\(e.file) still censuses only the file the picker LEFT — "
                          + "the code moved and the guard did not, which is the "
                          + "exact hole extraction was chosen to avoid")
        }
    }

    // MARK: - The invariants themselves, over BOTH corpora

    /// No provider id is named as a literal in either half of the split.
    ///
    /// Restated over the union rather than trusted to the migrated leg,
    /// because the two fail in different places: that one dies if the needle
    /// is renamed, this one dies if a literal appears.
    func testNoProviderLiteralInEitherHalfOfTheSplit() throws {
        let union = try ["Commissioning.swift", "RoutePicker.swift"]
            .map { try source($0) }.joined(separator: "\n")
        XCTAssertTrue(union.contains("func recordRoutesChoice"),
                      "POS: the walk reads the record writer, so a zero below is real")
        for literal in ["\"anthropic\"", "\"openai\"", "\"ollama\""] {
            XCTAssertEqual(union.components(separatedBy: literal).count - 1, 0,
                           "\(literal) is named in source: the id must come from the "
                           + "catalogue, never from a screen")
        }
    }

    /// THE MODEL FIELD IS NOT GATED ON THE CATALOGUE.
    ///
    /// The Ollama-only era's defect: a picker that renders models ONLY from a
    /// live catalogue leaves every provider the bridge folds to `Unsupported`
    /// unarmable. The field is unconditional; the list is an accelerator over
    /// it. A pasted second picker could have re-introduced this with the
    /// original leg still green.
    func testTheModelFieldIsUnconditionalAndNotGatedOnTheCatalogue() throws {
        let code = codeLines(try source("RoutePicker.swift"))
        let joined = code.joined(separator: "\n")
        XCTAssertTrue(joined.contains("TextField(\"\", text: $modelText"),
                      "POS: the free-text model field is present")
        guard let fieldIndex = code.firstIndex(where: {
            $0.contains("TextField(\"\", text: $modelText")
        }) else { return XCTFail("VOID: the model field is not in this file") }
        let before = code[..<fieldIndex].joined(separator: "\n")
        let opens = (before.components(separatedBy: "if case let .listed").count - 1)
                  + (before.components(separatedBy: "if case .listed").count - 1)
        XCTAssertEqual(opens, 0,
                       "the model field must not be rendered behind a `.listed` arm: "
                       + "a provider with no catalogue would be unarmable")
    }

    /// ONE key-write site across the whole split.
    func testExactlyOneKeyWriteSiteSurvivesTheSplit() throws {
        var writes = 0
        for name in ["Commissioning.swift", "RoutePicker.swift",
                     "NodesView.swift", "RootView.swift"] {
            let code = codeLines(try source(name))
            XCTAssertFalse(code.isEmpty, "\(name): the walk read nothing")
            writes += code.filter { $0.contains("keys.setProviderKey(") }.count
        }
        XCTAssertEqual(writes, 1,
                       "exactly ONE write site for the operator's key across the "
                       + "split; found \(writes)")
    }

    /// ONE HTTP request per SETTLED keystroke, not per keystroke.
    func testTheDebounceAndItsCancellationMovedWithThePoll() throws {
        let code = codeLines(try source("RoutePicker.swift"))
        let joined = code.joined(separator: "\n")
        XCTAssertTrue(joined.contains("pollDebounce"),
                      "POS: the debounce window has a name in this file")
        // SITE-SCOPED, NOT COUNTED. A `> 0` count was the first form of this
        // leg and a mutation exposed it: deleting the TAP arm's cancel left
        // the count at 1 and the leg green, because the debounce's own cancel
        // was still there. Two different cancels, one number, no way to say
        // which one died. So the claim names the site — the cancel inside
        // `schedulePoll`, which is the one that makes a keystroke burst into
        // a single request.
        guard let sched = code.firstIndex(where: { $0.contains("private func schedulePoll(for row:") })
        else { return XCTFail("VOID: the debounce entry point is not in this file") }
        let window = code[sched...].prefix(6).joined(separator: "\n")
        XCTAssertTrue(window.contains("pollTask?.cancel()"),
                      "`schedulePoll` must cancel the in-flight debounce before "
                      + "arming a new one, or every keystroke opens its own request")
    }

    // MARK: - The raise, and its reachability

    /// THE RAISE IS REACHABLE IN A SHIPPED BUILD.
    ///
    /// ARITY WOULD HAVE BEEN VACUOUS. `recordRoutesChoice` already had TWO
    /// production callers at `93d7394` and the phone still had no way to set a
    /// provider — the second was `RootView:238`, live code behind a value that
    /// is unconditionally `nil` in release. A count leg would have shipped
    /// green over the exact defect it was written for. So the claim is
    /// REACHABILITY: a commit path that is not inside a `#if DEBUG`.
    func testTheRoutesCommitIsReachableOutsideDebug() throws {
        let src = try source("RootView.swift")
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let commit = lines.firstIndex(where: {
            $0.contains("RoutePicker(keys: keys, ctaTitle:")
        }) else { return XCTFail("VOID: RootView does not present the picker") }

        // Walk UP from the commit site counting DEBUG gates still OPEN at that
        // line. This counts rather than greps because one `#if DEBUG`
        // anywhere in the file would fail a naive check and pass a real one.
        var depth = 0
        for line in lines[..<commit] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if DEBUG") { depth += 1 }
            if t.hasPrefix("#endif") && depth > 0 { depth -= 1 }
        }
        XCTAssertEqual(depth, 0,
                       "the picker's production call site is inside a `#if DEBUG`: "
                       + "a debug-only raise is the `RootView:238` defect again")

        XCTAssertTrue(src.contains("onOpenRoutes: { routesSheet = true }"),
                      "NODES must be able to raise it")
    }

    /// COMMIT RE-ARMS THE CORE, so the pill and the AGENT tile move without a
    /// relaunch.
    ///
    /// `AppState.commission` republishing does NOT re-run `RootView.init`:
    /// `configSource` is a `@StateObject` and the adopting `.task` carries no
    /// `id:`, so it does not re-fire on a value change. A commit that only
    /// wrote the record would leave every provider-derived surface reading
    /// `NO PROVIDER` until the next cold start — the control narrating an act
    /// that half-happened.
    func testTheRoutesCommitWritesInvalidatesAndRearms() throws {
        let src = try source("RootView.swift")
        guard let start = src.range(of: "RoutePicker(keys: keys, ctaTitle:") else {
            return XCTFail("VOID: no picker call site to read")
        }
        let block = String(src[start.lowerBound...].prefix(1800))
        XCTAssertTrue(block.contains("store.save(updated)"),
                      "the commit must persist the commission")
        XCTAssertTrue(block.contains("configSource.adopt(RootView.resolve(store: store))"),
                      "the PURE resolve must invalidate first, or a reading taken "
                      + "before the commit survives into the screen after it")
        XCTAssertTrue(block.contains("RootView.armedResolution(store: store, keys: keys)"),
                      "and the ARMED resolution must replace it, or the pill and the "
                      + "AGENT tile read NO PROVIDER until relaunch")
        // ORDER, not just presence: invalidate BEFORE re-arm.
        guard let pure = block.range(of: "RootView.resolve(store: store)"),
              let armed = block.range(of: "RootView.armedResolution(") else {
            return XCTFail("VOID: one of the two resolves is absent")
        }
        XCTAssertLessThan(pure.lowerBound, armed.lowerBound,
                          "the pure resolve must precede the armed one")
    }

    /// NODES RAISES AND DOES NOT COMMIT.
    /// RE-ANCHORED at the SETTINGS arc. The provider row MOVED, so the raise
    /// this leg was written to guard now happens on SETTINGS — reading
    /// `onOpenRoutes()` on NODES would have been a POS needle asserting the
    /// opposite of its intent. The RAISE-ONLY claim is unchanged and is now
    /// asserted where the row lives; NODES is held to a stronger bar in the
    /// same invocation: it raises nothing about routes at all.
    func testSettingsRaisesTheSheetAndWritesNoCommission() throws {
        let code = codeLines(try source("SettingsView.swift"))
        let joined = code.joined(separator: "\n")
        XCTAssertTrue(joined.contains("onOpenRoutes()"),
                      "POS: the provider row raises")
        XCTAssertEqual(code.filter { $0.contains("recordRoutesChoice") }.count, 0,
                       "SETTINGS must not write the record: it cannot re-arm the "
                       + "core, so a commit here would half-happen")
        XCTAssertEqual(code.filter { $0.contains("keys.setProviderKey(") }.count, 0,
                       "nor write a key")

        // NODES, same invocation: the row is gone, not mirrored. A second
        // raiser would be a second door onto one write path.
        let nodes = codeLines(try source("NodesView.swift"))
        XCTAssertEqual(nodes.filter { $0.contains("onOpenRoutes()") }.count, 0,
                       "NODES still raises the picker — the row moved but a door stayed")
        XCTAssertTrue(nodes.joined(separator: "\n").contains("onOpenSettings()"),
                      "VOID: the NODES walk read nothing — the absence above is vacuous")
    }

    // MARK: - readers

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func testSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func codeLines(_ src: String) -> [String] {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
    }
}
