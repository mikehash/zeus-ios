import XCTest
@testable import Zeus

final class WakeChimeTests: XCTestCase {

    private func fresh() -> UserDefaults {
        let name = "wake-chime-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testAFreshInstallIsSilent() {
        let d = fresh()
        XCTAssertFalse(WakeChimePreference.isOn(d))
        XCTAssertNil(WakeChime.sound(d))
    }

    func testTheStoredChoiceRoundTrips() {
        let d = fresh()
        WakeChimePreference.set(true, d)
        XCTAssertTrue(WakeChimePreference.isOn(d))
        WakeChimePreference.set(false, d)
        XCTAssertFalse(WakeChimePreference.isOn(d))
    }

    func testOnSelectsTheBeginRecordTone() {
        let d = fresh()
        WakeChimePreference.set(true, d)
        XCTAssertEqual(WakeChime.sound(d), 1113)
        // vacuity: the two states must differ
        WakeChimePreference.set(false, d)
        XCTAssertNotEqual(WakeChime.sound(d), 1113)
    }

    private func source(_ rel: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(rel)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Wiring: the chime fires where the mic actually opens, exactly once,
    /// AFTER `.listening` — a row with no caller would narrate a sound.
    func testTheMicOpenSitePlaysTheChime() throws {
        let src = try source("Sources/ZeusApp/Voice.swift")
        XCTAssertTrue(src.contains("func beginTap"), "POS control: file read")
        XCTAssertEqual(src.components(separatedBy: "WakeChime.play()").count - 1, 1)
        let listening = try XCTUnwrap(src.range(of: "state = .listening\n            WakeChime.play()"))
        XCTAssertFalse(listening.isEmpty)
    }

    /// Only `WakeChime.play` touches the system-sound API.
    func testOneSystemSoundCaller() throws {
        let narr = try source("Sources/ZeusApp/Narrator.swift")
        let voice = try source("Sources/ZeusApp/Voice.swift")
        XCTAssertTrue(narr.contains("enum WakeChime"), "POS control: file read")
        XCTAssertEqual(narr.components(separatedBy: "AudioServicesPlaySystemSound(").count - 1, 1)
        XCTAssertEqual(voice.components(separatedBy: "AudioServicesPlaySystemSound(").count - 1, 0)
    }
}
