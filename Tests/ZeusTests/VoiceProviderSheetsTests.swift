import XCTest
@testable import Zeus

/// Voice-wiring commit 3: the Settings "Voice provider" row and RootView's two
/// sheets. Flow tests drive `VoiceProviderSheets` directly; the source checks
/// pin the RootView/Settings wiring the flow cannot see.
final class VoiceProviderSheetsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "voice-sheets-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func choice(_ id: String, keyed: Bool) -> VoiceProviderChoice {
        VoiceProviderChoice(id: id, label: id, dialect: .openAiRealtime, hasKey: keyed)
    }

    // MARK: - Flow

    func testOpenRaisesOnlyThePicker() {
        var s = VoiceProviderSheets()
        XCTAssertFalse(s.pickerOpen)
        s.open()
        XCTAssertTrue(s.pickerOpen)
        XCTAssertNil(s.keyOnlyProvider)
    }

    func testPickStoresTheIdAndClosesThePicker() {
        var s = VoiceProviderSheets()
        s.open()
        s.pick("google", defaults)
        XCTAssertEqual(RealtimeProviderPreference.storedID(defaults), "google")
        XCTAssertFalse(s.pickerOpen)
        XCTAssertNil(s.keyOnlyProvider)
    }

    /// ADD KEY: picker closed AND key sheet open, for that id, in one step.
    /// It must not choose the provider.
    func testAddKeyClosesThePickerOpensKeyOnlyAndChoosesNothing() {
        var s = VoiceProviderSheets()
        s.open()
        s.addKey("openai")
        XCTAssertFalse(s.pickerOpen, "both sheets up at once")
        XCTAssertEqual(s.keyOnlyProvider, "openai")
        XCTAssertNil(RealtimeProviderPreference.storedID(defaults),
                     "ADD KEY must not pick the provider")
    }

    /// After the key lands, back to the picker — still not chosen for them.
    func testKeySavedReturnsToThePickerWithoutAutoPicking() {
        var s = VoiceProviderSheets()
        s.open()
        s.addKey("openai")
        s.keySaved("openai")
        XCTAssertTrue(s.pickerOpen)
        XCTAssertNil(s.keyOnlyProvider)
        XCTAssertNil(RealtimeProviderPreference.storedID(defaults),
                     "voice never auto-picks, including after a key save")
    }

    /// The scrim can close either sheet; it cannot open one.
    func testBindingsCloseButCannotOpen() {
        var s = VoiceProviderSheets()
        s.pickerPresented = true
        XCTAssertFalse(s.pickerOpen, "a binding opened the picker")
        s.open()
        s.pickerPresented = false
        XCTAssertFalse(s.pickerOpen)

        s.addKey("openai")
        s.keyOnlyPresented = true
        XCTAssertEqual(s.keyOnlyProvider, "openai")
        s.keyOnlyPresented = false
        XCTAssertNil(s.keyOnlyProvider)
    }

    func testSettingsValueReflectsTheResolvedChoice() {
        let state = VoiceProviderState.choices([choice("openai", keyed: true),
                                                choice("google", keyed: false)])
        XCTAssertEqual(VoiceProviderSheets.settingsValue(state, defaults), "NOT SET")
        RealtimeProviderPreference.set("openai", defaults)
        XCTAssertEqual(VoiceProviderSheets.settingsValue(state, defaults), "OPENAI")
        // Stored but keyless reads as NOT SET, not as the stored id.
        RealtimeProviderPreference.set("google", defaults)
        XCTAssertEqual(VoiceProviderSheets.settingsValue(state, defaults), "NOT SET")
        XCTAssertEqual(VoiceProviderSheets.settingsValue(.noRealtimeProvider, defaults),
                       "UNAVAILABLE")
    }

    // MARK: - Wiring (source)

    private func codeLines(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    /// RootView: pick → `voiceSheets.pick`, ADD KEY → `voiceSheets.addKey`,
    /// key sheet → `RoutePicker.KeyOnly` with `keySaved`. And NOT the route
    /// picker: a `RoutePicker(` inside the voice block would be the coupling.
    func testRootViewWiresBothSheetsThroughTheFlow() throws {
        let code = try codeLines("RootView.swift")
        XCTAssertFalse(code.isEmpty, "VOID: read nothing")
        guard let start = code.firstIndex(where: { $0.contains("if voiceSheets.pickerOpen {") }),
              let end = code.firstIndex(where: { $0.contains("if let config = gatewayEditorConfig, gatewayEditor {") }),
              start < end
        else { return XCTFail("VOID: the voice sheet block is not where expected") }
        let block = code[start..<end].joined(separator: "\n")
        XCTAssertTrue(block.contains("onPick: { id in voiceSheets.pick(id) }"))
        XCTAssertTrue(block.contains("onAddKey: { id in voiceSheets.addKey(id) }"))
        XCTAssertTrue(block.contains("RoutePicker.KeyOnly(keys: keys"))
        XCTAssertTrue(block.contains("onSaved: { saved in voiceSheets.keySaved(saved) }"))
        for banned in ["RoutePicker(keys:", "recordRoutesChoice", "store.save",
                       "keys.setProviderKey(", "providerKey(for:", "armedResolution"] {
            XCTAssertFalse(block.contains(banned),
                           "voice sheet block contains `\(banned)` — it must store a key and an id, nothing else")
        }
        XCTAssertEqual(code.filter { $0.contains("onOpenVoiceProvider: { voiceSheets.open() }") }.count, 1,
                       "the Settings row must be wired to open the picker")
    }

    /// ONE PICK WRITE SITE. The flow tests inject a suite, so an auto-pick
    /// written with the default `.standard` (`RealtimeProviderPreference.set(id)`)
    /// is invisible to them — exactly the slip a production auto-pick would be.
    /// So the write is counted at the source: one call, inside `pick`, and none
    /// in RootView's voice block or in Settings.
    func testThePreferenceIsWrittenOnlyByPick() throws {
        let code = try codeLines("VoiceProviderSheets.swift")
        let writes = code.indices.filter { code[$0].contains("RealtimeProviderPreference.set(") }
        XCTAssertEqual(writes.count, 1, "exactly one preference write site; found \(writes.count)")
        guard let pick = code.firstIndex(where: { $0.contains("mutating func pick(") }),
              let next = code[(pick + 1)...].firstIndex(where: { $0.contains("func ") }),
              let w = writes.first
        else { return XCTFail("VOID: `pick` or its write not found") }
        XCTAssertTrue(pick < w && w < next, "the one write must sit inside `pick`")
        let root = try codeLines("RootView.swift")
        XCTAssertEqual(root.filter { $0.contains("RealtimeProviderPreference.set(") }.count, 0)
    }

    /// Settings: the row raises, writes nothing, and the closure has no default.
    func testSettingsRowRaisesOnlyAndIsUndefaulted() throws {
        let code = try codeLines("SettingsView.swift")
        XCTAssertTrue(code.contains("var onOpenVoiceProvider: () -> Void"),
                      "declared un-defaulted")
        XCTAssertFalse(code.contains { $0.contains("onOpenVoiceProvider") && $0.contains("= {") },
                       "a default would let a call site ship the row dead")
        XCTAssertEqual(code.filter { $0.contains("onOpenVoiceProvider()") }.count, 1, "POS: the row raises")
        XCTAssertEqual(code.filter { $0.contains("RealtimeProviderPreference.set(") }.count, 0,
                       "Settings must not pick — the pick is RootView's")
    }
}
