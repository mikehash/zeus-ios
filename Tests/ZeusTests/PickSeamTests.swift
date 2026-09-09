import XCTest
@testable import Zeus

/// The capture seam that preselects a ROUTES row.
///
/// WHY IT EXISTS AS A TEST: `-zeusStep routes` opens the picker with
/// `providerPick == nil`, and the `SecureField` plus the enabled model field
/// are revealed by a row TAP. `simctl` has no tap primitive, so the keyed
/// state was one tap past the deepest state the capture seam could reach —
/// stated as a gap on the channel rather than papered over. `-zeusPick`
/// closes it.
///
/// 🔴 APERTURE, stated because half of this is a source census and a census
/// is the weaker instrument: the parser legs below are REAL behavioural legs
/// (`pickedRoute` is `static` and invocable from this target). The consumer
/// legs are a census, because the write happens in a SwiftUI `.onAppear` on a
/// `View` with `@State` and this target has no ViewInspector. The census
/// legs therefore assert the seam is SPELLED correctly — that it writes view
/// state and not the record — never that a captured frame is real. The frame
/// is its own receipt.
final class PickSeamTests: XCTestCase {

    // MARK: - Source access

    private func sourceFile(_ name: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // repo root
        let url = root.appendingPathComponent("Sources/ZeusApp/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Code lines only. The doc comments on this seam NAME the fields and the
    /// functions it must not call, so a whole-file needle would hit the very
    /// prose explaining the constraint — the `All systems nominal` fault from
    /// the seed cut, one commit-family over.
    private func codeLines(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("///") && !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - The parser (behavioural — the real instrument here)

    /// Absent flag is `nil`, not a fabricated row. Without this the seam
    /// would preselect on every launch and the UNSELECTED picker frame — the
    /// one already in the capture set — would become unreachable.
    func testAbsentFlagYieldsNil() {
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("-zeusPick"),
                       "control: the test runner must not itself pass the flag, or every leg below is vacuous")
        XCTAssertNil(LaunchArgs.pickedRoute)
    }

    /// The consumer is guarded on `providerPick == nil`, so a backstep into
    /// ROUTES cannot stomp a choice made by hand between the two appearances.
    ///
    /// MUT: delete the `providerPick == nil,` clause — this leg fires.
    func testTheSeamIsGuardedAgainstStompingAHandChoice() throws {
        let body = codeLines(try sourceFile("Commissioning.swift"))
        XCTAssertTrue(body.contains("if providerPick == nil, let seed = LaunchArgs.pickedRoute"),
                      "the seed must not overwrite a pick the operator has already made")
    }

    /// The seam writes VIEW state and NOT the record.
    ///
    /// This is the leg that matters: a seam that called `recordRoutesChoice`
    /// would make every captured frame a claim about the STORE, and the
    /// distinction between "was shown a preselection" and "chose" — which
    /// `provider: String?` exists to preserve — would be erased by a debug
    /// flag. MUT: add `commission.recordRoutesChoice(` inside the block.
    func testTheSeamWritesViewStateAndNotTheRecord() throws {
        let body = codeLines(try sourceFile("Commissioning.swift"))
        guard let range = body.range(of: "if providerPick == nil, let seed = LaunchArgs.pickedRoute") else {
            return XCTFail("VOID: the seam is not present — every leg below would pass vacuously")
        }
        let block = String(body[range.lowerBound...].prefix(300))

        // POS control, same invocation: the block demonstrably contains the
        // writes it SHOULD have, so a miss below is about the tree and not
        // about the slice.
        XCTAssertTrue(block.contains("providerPick = seed.id"),
                      "POS: the seam must write the view's pick")
        XCTAssertTrue(block.contains("modelText = m"),
                      "POS: the seam must write the view's model field")

        XCTAssertFalse(block.contains("recordRoutesChoice"),
                       "the seam must not write the commission record")
        XCTAssertFalse(block.contains("setProviderKey"),
                       "the seam must not write a key")
        XCTAssertFalse(block.contains("step ="),
                       "the seam must not advance the flow")
    }

    /// No key operand exists. A flag that seeded `keyText` would put a
    /// secret-shaped literal into shell history to photograph dots.
    ///
    /// MUT: add a third positional writing `keyText` — this leg fires.
    func testTheSeamHasNoKeyOperand() throws {
        let launch = codeLines(try sourceFile("LaunchArgs.swift"))
        XCTAssertTrue(launch.contains("static var pickedRoute"),
                      "POS: control on the subject's own presence")
        XCTAssertFalse(launch.contains("keyText"),
                       "no launch argument may carry or seed a key")

        let body = codeLines(try sourceFile("Commissioning.swift"))
        guard let range = body.range(of: "if providerPick == nil, let seed = LaunchArgs.pickedRoute") else {
            return XCTFail("VOID: the seam is not present")
        }
        let block = String(body[range.lowerBound...].prefix(300))
        XCTAssertFalse(block.contains("keyText"),
                       "the seam must not seed the secure field")
    }

    /// The seam is DEBUG-only on the producing side, so a shipped build
    /// cannot preselect a provider it was launched with.
    func testTheSeamIsDebugGated() throws {
        let launch = try sourceFile("LaunchArgs.swift")
        guard let range = launch.range(of: "static var pickedRoute") else {
            return XCTFail("VOID: the subject is absent")
        }
        let block = String(launch[range.lowerBound...].prefix(900))
        XCTAssertTrue(block.contains("#if DEBUG"), "the seam must be DEBUG-gated")
        XCTAssertTrue(block.contains("#else"), "the release arm must be explicit")
        XCTAssertTrue(block.contains("return nil"), "the release arm must answer nil")
    }
}
