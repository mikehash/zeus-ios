import XCTest
@testable import Zeus

/// The picker SCREEN's decisions, asserted on the pure presentation layer the
/// view lays out (no in-process renderer), plus a source census that the view
/// never becomes a second key-write site.
final class VoiceProviderPickerViewTests: XCTestCase {

    private func choice(_ id: String, _ label: String, key: Bool,
                        _ d: RealtimeDialect = .openAiRealtime) -> VoiceProviderChoice {
        VoiceProviderChoice(id: id, label: label, dialect: d, hasKey: key)
    }

    // MARK: - Rows

    /// A keyed row picks; a keyless row raises add-key. If a keyless row
    /// picked, `connect(for:)` would throw `.noKey` a screen later for a
    /// choice this screen accepted.
    func testKeyedRowPicksAndKeylessRowRaisesAddKey() {
        let rows = VoiceProviderPickerPresentation.rows(.choices([
            choice("openai", "OpenAI", key: true),
            choice("google", "Google", key: false, .geminiLive),
        ]))
        XCTAssertEqual(rows.map(\.id), ["openai", "google"], "model order is kept")
        XCTAssertEqual(rows.map(\.action), [.pick("openai"), .addKey("google")])
        XCTAssertEqual(rows.map(\.badge), [VoiceProviderPickerPresentation.keyBadge,
                                           VoiceProviderPickerPresentation.noKeyBadge])
        XCTAssertNotEqual(VoiceProviderPickerPresentation.keyBadge,
                          VoiceProviderPickerPresentation.noKeyBadge,
                          "vacuity: the two badges must be distinguishable")
    }

    /// The empty state has NO rows — it renders its own copy, never an empty
    /// list that looks like "still loading".
    func testNoRealtimeProviderHasNoRowsAndNoKeyHint() {
        XCTAssertTrue(VoiceProviderPickerPresentation.rows(.noRealtimeProvider).isEmpty)
        XCTAssertFalse(VoiceProviderPickerPresentation.showsNoKeyHint(.noRealtimeProvider),
                       "no providers is not 'add a key' — the fix copy would be a lie")
    }

    /// Choices-but-no-key shows the fix hint; one stored key hides it.
    func testNoKeyHintOnlyWhenEveryChoiceLacksAKey() {
        let none = VoiceProviderState.choices([choice("openai", "OpenAI", key: false),
                                               choice("google", "Google", key: false, .geminiLive)])
        let one = VoiceProviderState.choices([choice("openai", "OpenAI", key: false),
                                              choice("google", "Google", key: true, .geminiLive)])
        XCTAssertTrue(VoiceProviderPickerPresentation.showsNoKeyHint(none))
        XCTAssertFalse(VoiceProviderPickerPresentation.showsNoKeyHint(one))
    }

    /// End to end through the model: a whitespace key (missing per the model)
    /// reaches the screen as an add-key row, not a pick.
    func testWhitespaceKeyReachesTheScreenAsAddKey() {
        let keys = InMemoryProviderKeyStore()
        keys.setProviderKey("  ", for: "openai")
        let state = VoiceProviderPicker.state(
            catalog: StubCatalog(rows: [ProviderRow(id: "openai", label: "OpenAI", shape: .key)]),
            keys: keys,
            dialect: { _ in .openAiRealtime })
        XCTAssertEqual(VoiceProviderPickerPresentation.rows(state).map(\.action), [.addKey("openai")])
    }

    // MARK: - Census: the screen never collects or reads key bytes

    func testTheScreenIsNotAKeyWriteOrReadSite() throws {
        let code = try codeLines("VoiceProviderPickerView.swift")
        XCTAssertGreaterThan(code.filter { $0.contains("onAddKey(") }.count, 0,
                             "control: the census reads the real file")
        for needle in ["setProviderKey(", "providerKey(for:", "SecureField", "UserDefaults", "resolveRealtime("] {
            XCTAssertEqual(code.filter { $0.contains(needle) }.count, 0,
                           "\(needle) in the picker screen — key handling belongs to the model / RoutePicker")
        }
    }

    private func codeLines(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/\(name)")
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(domain: "VOID", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "VOID: no source at \(url.path)"])
        }
        return body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }
}
