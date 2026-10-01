import XCTest
import AVFoundation
@testable import Zeus

final class SpeechAudioTests: XCTestCase {
    private final class FakeSession: SpeechAudioSession {
        var category: AVAudioSession.Category = .record
        var active = false
        var failCategory = false
        func setCategory(_ c: AVAudioSession.Category, mode: AVAudioSession.Mode,
                         options: AVAudioSession.CategoryOptions) throws {
            if failCategory { throw NSError(domain: "fake", code: 1) }
            category = c
        }
        func setActive(_ a: Bool, options: AVAudioSession.SetActiveOptions) throws { active = a }
    }

    /// The defect: a session left in `.record` by the mic must be moved to a
    /// category that renders output before an utterance is spoken.
    func testPrepareMovesARecordSessionToPlayback() {
        let s = FakeSession()
        XCTAssertEqual(s.category, .record)
        XCTAssertTrue(SpeechAudio.prepare(s))
        XCTAssertEqual(s.category, .playback)
        XCTAssertNotEqual(s.category, .record)
        XCTAssertTrue(s.active)
    }

    /// `.soloAmbient`/`.ambient` obey the silent switch; `.record` is mute.
    func testTheSpeechCategoryIsNotSilencedByTheSwitchOrTheMic() {
        XCTAssertFalse([.ambient, .soloAmbient, .record].contains(SpeechAudio.category))
    }

    func testAFailedCategoryIsReportedNotThrown() {
        let s = FakeSession(); s.failCategory = true
        XCTAssertFalse(SpeechAudio.prepare(s))
    }

    /// Wiring: the narrator's single speak site calls prepare on the shared
    /// session. Strip comments so a doc mention cannot satisfy it.
    func testTheNarratorSpeakSitePreparesTheSession() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Narrator.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { l -> Substring in
                if let r = l.range(of: "//") { return l[..<r.lowerBound] }
                return l
            }.joined(separator: "\n")
        XCTAssertEqual(code.components(separatedBy: "SpeechAudio.prepare(AVAudioSession.sharedInstance())").count - 1, 1)
        XCTAssertEqual(code.components(separatedBy: "synth.speak(").count - 1, 1, "POS control: the speak site exists")
    }
}
