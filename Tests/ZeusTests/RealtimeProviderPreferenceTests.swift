import XCTest
@testable import Zeus

final class RealtimeProviderPreferenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "realtime-pref-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func choice(_ id: String, keyed: Bool,
                        dialect: RealtimeDialect = .openAiRealtime) -> VoiceProviderChoice {
        VoiceProviderChoice(id: id, label: id.uppercased(), dialect: dialect, hasKey: keyed)
    }

    func testAStoredKeyedChoiceResolves() {
        let state = VoiceProviderState.choices([choice("openai", keyed: true),
                                                choice("google", keyed: true, dialect: .geminiLive)])
        RealtimeProviderPreference.set("google", defaults)
        XCTAssertEqual(RealtimeProviderPreference.resolved(in: state, defaults)?.id, "google")
    }

    func testNothingStoredIsNilEvenWithKeyedChoices() {
        // Voice never auto-picks: keyed choices exist, nothing stored → nil.
        let state = VoiceProviderState.choices([choice("openai", keyed: true)])
        XCTAssertNil(RealtimeProviderPreference.storedID(defaults))
        XCTAssertNil(RealtimeProviderPreference.resolved(in: state, defaults))
    }

    func testAStaleIdIsNilNotASubstitute() {
        let state = VoiceProviderState.choices([choice("openai", keyed: true)])
        RealtimeProviderPreference.set("vanished", defaults)
        XCTAssertNil(RealtimeProviderPreference.resolved(in: state, defaults))
        // Control: the same state DOES resolve a live id, so the nil above is
        // about staleness, not a state that can never resolve.
        RealtimeProviderPreference.set("openai", defaults)
        XCTAssertNotNil(RealtimeProviderPreference.resolved(in: state, defaults))
    }

    func testAStoredChoiceWithoutAKeyIsNil() {
        let state = VoiceProviderState.choices([choice("openai", keyed: false)])
        RealtimeProviderPreference.set("openai", defaults)
        XCTAssertNil(RealtimeProviderPreference.resolved(in: state, defaults))
        // The stored id survives — adding the key later restores the pick.
        XCTAssertEqual(RealtimeProviderPreference.storedID(defaults), "openai")
        let keyed = VoiceProviderState.choices([choice("openai", keyed: true)])
        XCTAssertEqual(RealtimeProviderPreference.resolved(in: keyed, defaults)?.id, "openai")
    }

    func testNoRealtimeProviderIsNil() {
        RealtimeProviderPreference.set("openai", defaults)
        XCTAssertNil(RealtimeProviderPreference.resolved(in: .noRealtimeProvider, defaults))
    }

    func testSetNilClearsAndOnlyTheIdIsWritten() {
        RealtimeProviderPreference.set("openai", defaults)
        let written = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(Array(written.keys), [RealtimeProviderPreference.key],
                       "the preference writes exactly one entry")
        XCTAssertEqual(written[RealtimeProviderPreference.key] as? String, "openai",
                       "the entry is the provider id and nothing else")
        RealtimeProviderPreference.set(nil, defaults)
        XCTAssertNil(RealtimeProviderPreference.storedID(defaults))
    }
}
