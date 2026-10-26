import XCTest
@testable import Zeus

/// Every leg owns its catalog and dialect map (`StubCatalog`, a closure), so a
/// leg about filtering is not a leg about whichever providers the linked core
/// carries today. Legs that name the REAL core say so in their name.
final class VoiceProviderPickerTests: XCTestCase {

    private let rows = [
        ProviderRow(id: "anthropic", label: "Anthropic", shape: .key),
        ProviderRow(id: "openai", label: "OpenAI", shape: .key),
        ProviderRow(id: "ollama", label: "Ollama", shape: .url),
        ProviderRow(id: "google", label: "Google", shape: .key),
    ]

    private let map: RealtimeDialectLookup = { id in
        switch id {
        case "openai": return .openAiRealtime
        case "google": return .geminiLive
        case "anthropic", "ollama": return RealtimeDialect.none
        default: return nil
        }
    }

    private func choices(_ s: VoiceProviderState,
                         file: StaticString = #filePath, line: UInt = #line) -> [VoiceProviderChoice] {
        guard case let .choices(c) = s else {
            XCTFail("expected choices, got \(s)", file: file, line: line); return []
        }
        return c
    }

    func testOnlyRowsWithADialectAppearInCatalogOrder() {
        let s = VoiceProviderPicker.state(catalog: StubCatalog(rows: rows),
                                          keys: InMemoryProviderKeyStore(),
                                          dialect: map)
        let c = choices(s)
        XCTAssertEqual(c.map(\.id), ["openai", "google"])
        XCTAssertEqual(c.map(\.dialect), [.openAiRealtime, .geminiLive])
        XCTAssertEqual(c.map(\.label), ["OpenAI", "Google"], "label is the catalog's, not the wire id")
    }

    /// An id the core REFUSES (`nil`) is hidden, not shown as a choice that
    /// would then fail in `resolveRealtime`.
    func testAnIdTheCoreRefusesIsHidden() {
        let s = VoiceProviderPicker.state(
            catalog: StubCatalog(rows: rows + [ProviderRow(id: "mystery", label: "Mystery", shape: .key)]),
            keys: InMemoryProviderKeyStore(), dialect: map)
        XCTAssertFalse(choices(s).contains { $0.id == "mystery" })
    }

    func testNoRealtimeProviderIsItsOwnState() {
        let s = VoiceProviderPicker.state(catalog: StubCatalog(rows: rows),
                                          keys: InMemoryProviderKeyStore(),
                                          dialect: { _ in RealtimeDialect.none })
        XCTAssertEqual(s, .noRealtimeProvider)
        // Vacuity control: the same catalog with a real map is NOT empty, so
        // the empty answer above came from the dialect, not the catalog.
        XCTAssertNotEqual(VoiceProviderPicker.state(catalog: StubCatalog(rows: rows),
                                                    keys: InMemoryProviderKeyStore(),
                                                    dialect: map),
                          .noRealtimeProvider)
    }

    func testHasKeyReflectsTheTextOnboardingKeychainEntry() {
        let keys = InMemoryProviderKeyStore()
        keys.setProviderKey("sk-live", for: "openai")
        keys.setProviderKey("   ", for: "google")
        let c = choices(VoiceProviderPicker.state(catalog: StubCatalog(rows: rows),
                                                  keys: keys, dialect: map))
        XCTAssertEqual(c.first { $0.id == "openai" }?.hasKey, true)
        XCTAssertEqual(c.first { $0.id == "google" }?.hasKey, false,
                       "whitespace is not a key — the core would refuse it")
    }

    func testConnectWithoutAKeyRefusesBeforeTheCore() {
        let choice = VoiceProviderChoice(id: "openai", label: "OpenAI",
                                         dialect: .openAiRealtime, hasKey: false)
        XCTAssertThrowsError(try VoiceProviderPicker.connect(for: choice,
                                                             keys: InMemoryProviderKeyStore(),
                                                             model: "gpt-realtime",
                                                             baseURLOverride: nil)) {
            XCTAssertEqual($0 as? VoiceProviderPicker.ConnectError, .noKey(providerId: "openai"))
        }
    }

    /// REAL CORE: the stored key reaches `resolveRealtime` and comes back in
    /// the dialect's auth shape. Pure function, no socket.
    func testRealCoreConnectCarriesTheStoredKeyInEachDialectsShape() throws {
        let keys = InMemoryProviderKeyStore()
        keys.setProviderKey("sk-test-openai", for: "openai")
        keys.setProviderKey("g-test-key", for: "google")

        let oa = try VoiceProviderPicker.connect(
            for: VoiceProviderChoice(id: "openai", label: "OpenAI", dialect: .openAiRealtime, hasKey: true),
            keys: keys, model: "gpt-realtime", baseURLOverride: nil)
        XCTAssertTrue(oa.headers.contains { $0.name == "Authorization" && $0.value == "Bearer sk-test-openai" },
                      "openai carries the key as a bearer header: \(oa.headers.map(\.name))")
        XCTAssertFalse(oa.url.contains("sk-test-openai"), "openai key must not ride the URL")

        let gm = try VoiceProviderPicker.connect(
            for: VoiceProviderChoice(id: "google", label: "Google", dialect: .geminiLive, hasKey: true),
            keys: keys, model: "unused", baseURLOverride: nil)
        XCTAssertTrue(gm.url.contains("key=g-test-key"), "gemini carries the key in the query: \(gm.url)")
        XCTAssertFalse(gm.headers.contains { $0.value.contains("g-test-key") })
    }

    /// REAL CORE: the published catalog yields at least one voice choice, so
    /// the empty-state is not what a stock build shows.
    func testRealCoreCatalogOffersOpenAIAndGoogle() {
        let ids = choices(VoiceProviderPicker.state(catalog: CoreProviderCatalog(),
                                                    keys: InMemoryProviderKeyStore())).map(\.id)
        XCTAssertEqual(Set(ids), ["openai", "google"])
    }
}
