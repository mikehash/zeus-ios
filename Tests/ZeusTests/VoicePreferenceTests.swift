import XCTest
import AVFoundation
@testable import Zeus

final class VoicePreferenceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "voice-pref-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private var english: [AVSpeechSynthesisVoice] {
        VoicePreference.choices(AVSpeechSynthesisVoice.speechVoices())
    }

    /// Absent key = AUTO, and AUTO is the pre-existing pick — a fresh install sounds unchanged.
    func testAFreshInstallResolvesToTheAutoPick() throws {
        let all = AVSpeechSynthesisVoice.speechVoices()
        try XCTSkipIf(english.isEmpty, "no English voices on this runtime")
        let d = freshDefaults()
        XCTAssertNil(VoicePreference.storedID(d))
        XCTAssertEqual(UtteranceShape.make("x", pitch: 0.9, defaults: d, voices: all).voice?.identifier,
                       VoicePreference.auto(all)?.identifier)
        XCTAssertNotNil(VoicePreference.auto(all), "POS control: auto picks something")
    }

    /// The stored identifier reaches the utterance the synthesizer is handed.
    func testTheStoredVoiceReachesTheUtterance() throws {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let auto = VoicePreference.auto(all)?.identifier
        let other = english.first { $0.identifier != auto }
        let pick = try XCTUnwrap(other, "needs a non-AUTO English voice on this runtime")
        let d = freshDefaults()
        VoicePreference.set(pick.identifier, d)
        let got = UtteranceShape.make("x", pitch: 0.9, defaults: d, voices: all).voice?.identifier
        XCTAssertEqual(got, pick.identifier)
        XCTAssertNotEqual(got, auto, "vacuity: the pick must differ from what AUTO would give")
    }

    /// A stored voice that is no longer installed falls back to AUTO, never to nil/silence.
    func testAnUninstalledStoredVoiceFallsBackToAuto() {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let d = freshDefaults()
        VoicePreference.set("com.example.voice.gone", d)
        XCTAssertEqual(VoicePreference.resolve(defaults: d, voices: all)?.identifier,
                       VoicePreference.auto(all)?.identifier)
        XCTAssertEqual(VoicePreference.label("com.example.voice.gone", in: all), "AUTO")
    }

    /// The row cycles AUTO → every English voice once → AUTO, and set(nil) clears the key.
    func testTheCycleVisitsEveryChoiceThenReturnsToAuto() throws {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let list = english
        try XCTSkipIf(list.isEmpty, "no English voices on this runtime")
        var seen: [String] = []
        var id: String? = VoicePreference.next(after: nil, in: all)
        while let cur = id {
            seen.append(cur)
            XCTAssertLessThanOrEqual(seen.count, list.count, "cycle must terminate")
            if seen.count > list.count { break }
            id = VoicePreference.next(after: cur, in: all)
        }
        XCTAssertEqual(seen, list.map(\.identifier))
        let d = freshDefaults()
        VoicePreference.set(list[0].identifier, d)
        VoicePreference.set(nil, d)
        XCTAssertNil(VoicePreference.storedID(d))
    }

    /// Structural: the speak site gets its voice only via the shaper — a bypass
    /// (`utterance.voice =` at the speak site) would let the row persist a voice
    /// the synthesizer never hears.
    func testTheSpeakSiteTakesItsVoiceOnlyFromTheShaper() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Narrator.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("VoicePreference.resolve("), "POS control: file read, shaper resolves")
        XCTAssertEqual(src.components(separatedBy: "u.voice = VoicePreference.resolve(").count - 1, 1)
        XCTAssertEqual(src.components(separatedBy: "utterance.voice =").count - 1, 0)
    }
}
