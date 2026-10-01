import XCTest
import AVFoundation
@testable import Zeus

final class SpeechRateTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "speech-rate-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// A fresh install must sound exactly as it did before the preference.
    func testAFreshInstallSpeaksAtTheSystemDefaultRate() {
        let d = freshDefaults()
        XCTAssertEqual(SpeechRatePreference.current(d), .normal)
        XCTAssertEqual(UtteranceShape.make("x", pitch: 0.9, defaults: d).rate,
                       AVSpeechUtteranceDefaultSpeechRate)
    }

    /// The stored step reaches the utterance the synthesizer is handed.
    func testTheStoredRateReachesTheUtterance() {
        let d = freshDefaults()
        SpeechRatePreference.set(.fast, d)
        let fast = UtteranceShape.make("x", pitch: 0.9, defaults: d).rate
        SpeechRatePreference.set(.slow, d)
        let slow = UtteranceShape.make("x", pitch: 0.9, defaults: d).rate
        XCTAssertNotEqual(fast, slow)
        XCTAssertGreaterThan(fast, AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertLessThan(slow, AVSpeechUtteranceDefaultSpeechRate)
    }

    /// Pitch is product identity and must not be moved by the rate row.
    func testPitchIsUntouchedByRate() {
        let d = freshDefaults()
        SpeechRatePreference.set(.fast, d)
        XCTAssertEqual(UtteranceShape.make("x", pitch: 0.9, defaults: d).pitchMultiplier, 0.9)
    }

    func testTheRowCyclesEveryStepAndWraps() {
        XCTAssertEqual(SpeechRatePreference.slow.next, .normal)
        XCTAssertEqual(SpeechRatePreference.normal.next, .fast)
        XCTAssertEqual(SpeechRatePreference.fast.next, .slow)
    }

    /// Wiring: the narrator's speak site must build through UtteranceShape,
    /// or the row would persist a choice the synthesizer never hears.
    func testTheNarratorSpeakSiteShapesThroughThePreference() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Narrator.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("SpeechRatePreference"), "POS control: file read")
        XCTAssertEqual(src.components(separatedBy: "UtteranceShape.make(line").count - 1, 1)
        // exactly one construction site — the shaper's own; a second means a bypass
        XCTAssertEqual(src.components(separatedBy: "AVSpeechUtterance(string: line)").count - 1, 1)
    }
}
