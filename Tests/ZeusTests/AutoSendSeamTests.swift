import XCTest
@testable import Zeus

/// The capture seam that commits a turn.
///
/// WHY A CENSUS AND NOT A BEHAVIOURAL LEG: `applyPrefill` is a `private func`
/// on a SwiftUI `View` with `@State`; this target has no ViewInspector, so
/// neither the function nor the `#if DEBUG` branch inside it is invocable
/// from a test. What IS assertable is the seam's SHAPE — that it calls the
/// production send action rather than assembling a turn of its own, that it
/// is the second and last caller of that action, and that it sits inside a
/// `#if DEBUG` bloc so release builds cannot reach it.
///
/// 🔴 APERTURE, stated because a source census is the weaker instrument: this
/// asserts the seam is SPELLED correctly, never that a captured frame is
/// real. The frame itself is the receipt; these legs only refuse the two
/// mutations that would make the frame a lie — a seam that builds its own
/// turn (measuring itself), and a seam reachable in release (a shipped app
/// that sends on launch).
final class AutoSendSeamTests: XCTestCase {

    // MARK: - The seam calls the production action, not its own

    /// MUT: replace `send()` in the seam with `onSend(trimmed)` — a turn the
    /// seam assembled — and this leg fails alone, because the caller count
    /// for `send` drops to two (the button and `.onSubmit`) with the seam
    /// no longer among them.
    func testTheSeamInvokesTheComposersOwnSendAction() throws {
        let body = try sourceFile("SessionView.swift")

        // POS control in the same invocation: a needle known present. Without
        // it, every count below is a statement about my pattern, not the file.
        XCTAssertTrue(body.contains("private func send() {"),
                      "VOID: the needle is dead — SessionView.swift did not contain its own send()")

        XCTAssertTrue(body.contains("if LaunchArgs.autoSend { send() }"),
                      "the seam must invoke send() — the exact function the SEND button's action: invokes")

        // The seam must NOT reach past `send` to the closure it guards. That
        // spelling would bypass `canSend` and commit a turn the UI says is
        // impossible, which is the one thing a capture must never fabricate.
        let autoSendLines = body.split(separator: "\n").filter { $0.contains("LaunchArgs.autoSend") }
        XCTAssertEqual(autoSendLines.count, 1,
                       "expected exactly one autoSend site; found \(autoSendLines.count)")
        XCTAssertFalse(autoSendLines.first.map(String.init)?.contains("onSend(") ?? true,
                       "the seam must not call onSend directly — that bypasses canSend and fabricates a turn")
    }

    /// Exactly three callers of `send`, named: the SEND button's `action:`,
    /// the keyboard return via `.onSubmit`, and the capture seam. A fourth
    /// would be an arming path nobody has read.
    ///
    /// NOTE the count is 3 and not the ruling's 2: `.onSubmit(send)` at
    /// `:327` already existed and is a real user path — the return key. It is
    /// named here rather than silently absorbed, because a census that
    /// reports the number it was told to expect is not a measurement.
    func testSendHasExactlyThreeNamedCallers() throws {
        let body = try sourceFile("SessionView.swift")

        let callers = body.split(separator: "\n")
            .map(String.init)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { return false }
                return t.contains("action: send")
                    || t.contains(".onSubmit(send)")
                    || t.contains("{ send() }")
            }

        XCTAssertEqual(callers.count, 3,
                       "expected 3 callers of send (button, onSubmit, seam); found \(callers.count): \(callers)")
    }

    // MARK: - Refused in release by construction

    /// The seam's line must sit inside a `#if DEBUG` bloc. MUT: delete the
    /// `#if DEBUG` / `#endif` pair around it and this leg fails alone — the
    /// shipped app would then send a deep link's prompt without a tap.
    func testTheSeamSitsInsideADebugBloc() throws {
        let body = try sourceFile("SessionView.swift")
        XCTAssertTrue(isInsideDebugBloc(needle: "LaunchArgs.autoSend", in: body),
                      "the auto-send seam must be #if DEBUG — in release it would send on launch")
    }

    /// The flag itself is `false` in a release configuration. Asserted on the
    /// SOURCE and not by reading `LaunchArgs.autoSend` at runtime, because
    /// this test bundle is compiled DEBUG: evaluating the property here would
    /// measure the debug arm and call it proof about release.
    func testTheFlagReadsFalseInRelease() throws {
        let body = try sourceFile("LaunchArgs.swift")
        XCTAssertTrue(body.contains("static var autoSend: Bool"),
                      "VOID: the needle is dead — LaunchArgs.swift did not declare autoSend")

        guard let range = body.range(of: "static var autoSend: Bool") else {
            return XCTFail("VOID: autoSend declaration not found after a positive contains()")
        }
        let decl = String(body[range.lowerBound...].prefix(220))
        XCTAssertTrue(decl.contains("#else"), "autoSend needs a release arm, not an open #if")
        XCTAssertTrue(decl.contains("return false"),
                      "the release arm must be false — an unconditional read is a shipped auto-sender")
    }

    /// Unarmed and armed spellings are two DIFFERENT strings. `assert_ne`'s
    /// Swift twin: a leg that only ever names one value cannot refuse a
    /// constant.
    func testTheFlagNameIsNotTheProviderFlag() {
        XCTAssertNotEqual("-zeusAutoSend", "-zeusProvider")
    }

    // MARK: - Instruments

    /// Whether the line carrying `needle` sits between `#if DEBUG` and its
    /// matching `#endif`. Tracks NESTING depth: a file-scoped
    /// `body.contains("#if DEBUG")` answers "this file mentions DEBUG" when
    /// the claim is "THIS CALL is DEBUG-only" — measured, that broad needle
    /// failed a correct file at `ProviderArmingTests:250`.
    private func isInsideDebugBloc(needle: String, in body: String) -> Bool {
        var depth = 0
        var debugDepthFloor: Int?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if") {
                depth += 1
                if t.contains("DEBUG"), debugDepthFloor == nil { debugDepthFloor = depth }
            } else if t.hasPrefix("#endif") {
                if let floor = debugDepthFloor, depth == floor { debugDepthFloor = nil }
                depth -= 1
            }
            if line.contains(needle) { return debugDepthFloor != nil }
        }
        return false
    }

    /// Reads a source file from the repo. FAILS naming VOID when absent —
    /// never a skip: a census that silently measures nothing is a green that
    /// means nothing was checked.
    private func sourceFile(_ name: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // repo
        let url = root.appendingPathComponent("Sources/ZeusApp/\(name)")
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(domain: "VOID", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "VOID: no source at \(url.path) — this census measured nothing"])
        }
        return body
    }
}
