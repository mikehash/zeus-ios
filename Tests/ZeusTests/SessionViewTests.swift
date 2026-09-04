import XCTest
@testable import Zeus

/// The header identifier was the literal `"SESSION-01"` for three commits
/// while the real gateway-named id sat one field away at `Session.swift:197`,
/// `private` and with no reader. Same class as `"last seen t-12min"`: a value
/// with the SHAPE of data that nothing recorded — and worse, because the true
/// value existed and was being ignored rather than merely absent.
///
/// The derivation is a `static func` for the reason HomeView's six are: a
/// SwiftUI body is not observable in-process, so a derivation left inline in
/// the view is guardable only by screenshot — which is exactly how the three
/// literal-status defects survived.
/// Local conformer. `ScriptedTransport` is `private` to the failure-test file
/// and stays that way — widening a test helper's access to reach it from a
/// second file couples two suites that share nothing but a protocol.
private struct SilentTransport: SessionTransport {
    func stream(prompt: String) -> AsyncThrowingStream<SessionFrame, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
final class SessionViewTests: XCTestCase {

    // MARK: - The absence arm

    /// Before any turn the gateway has named nothing. The honest render is an
    /// absence, not a placeholder number.
    func testNilSessionRendersEmDashNotANumber() {
        let title = SessionView.sessionTitle(for: nil)
        XCTAssertEqual(title, "SESSION · —")
        XCTAssertFalse(title.contains("01"), "a fabricated ordinal is the defect this replaced")
    }

    /// An empty string is the same absence as nil — a gateway that sends
    /// `"session_id": ""` must not produce `"SESSION · "`.
    func testEmptySessionIsTreatedAsAbsent() {
        XCTAssertEqual(SessionView.sessionTitle(for: ""), "SESSION · —")
    }

    // MARK: - The named arm

    func testNamedSessionRendersTruncatedUppercaseID() {
        let title = SessionView.sessionTitle(for: "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        XCTAssertEqual(title, "SESSION · A1B2C3D4")
    }

    /// VACUITY FLOOR for the truncation: an id SHORTER than the bound must
    /// render whole. Without this leg a `prefix` bug that returned "" would
    /// pass every other assertion in the absence direction.
    func testShortSessionRendersWhole() {
        XCTAssertEqual(SessionView.sessionTitle(for: "abc"), "SESSION · ABC")
    }

    /// The two arms must not collapse. `assert_ne`-style: a derivation that
    /// returned the same string for both states would satisfy neither claim
    /// while looking correct in a screenshot of either.
    func testNamedAndAbsentArmsDiffer() {
        XCTAssertNotEqual(
            SessionView.sessionTitle(for: nil),
            SessionView.sessionTitle(for: "deadbeef")
        )
    }

    // MARK: - The engine mirror

    /// The label starts absent. The engine holds a `SessionIDBox` from
    /// construction, but the BOX being non-nil is not the same claim as the
    /// gateway having NAMED an id.
    func testEngineLabelStartsNil() {
        let engine = SessionEngine(transport: SilentTransport())
        XCTAssertNil(engine.sessionLabel)
    }
}
