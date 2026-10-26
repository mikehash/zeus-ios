import XCTest
@testable import Zeus

/// KEY-ONLY MODE: the voice picker's ADD KEY stores a key and moves nothing
/// else. The route sheet's CTA runs `onCommit` → `recordRoutesChoice` →
/// `store.save` → re-arm, so routing ADD KEY there would repoint text chat.
final class RoutePickerKeyOnlyTests: XCTestCase {

    // MARK: - The shared write helper

    func testStoreKeyTrimsAndWrites() {
        let keys = InMemoryProviderKeyStore()
        XCTAssertTrue(RoutePicker.storeKey("  sk-oai \n", for: "openai", in: keys))
        XCTAssertEqual(keys.providerKey(for: "openai"), "sk-oai")
    }

    /// Blank refuses and writes nothing. A stored blank would read KEY STORED
    /// in the voice picker for a key the core refuses.
    func testStoreKeyRefusesBlankAndLeavesTheStoreUntouched() {
        let keys = InMemoryProviderKeyStore()
        keys.setProviderKey("existing", for: "openai")
        XCTAssertFalse(RoutePicker.storeKey("   \n", for: "openai", in: keys))
        XCTAssertEqual(keys.providerKey(for: "openai"), "existing",
                       "a blank save must not overwrite a stored key")
        XCTAssertFalse(RoutePicker.storeKey("", for: "google", in: keys))
        XCTAssertNil(keys.providerKey(for: "google"))
    }

    // MARK: - KeyOnly.save

    func testSaveStoresTheKeyForTheGivenProviderAndReportsOnce() {
        let keys = InMemoryProviderKeyStore()
        var saved: [String] = []
        RoutePicker.KeyOnly.save("sk-g", for: "google", in: keys) { saved.append($0) }
        XCTAssertEqual(keys.providerKey(for: "google"), "sk-g")
        XCTAssertNil(keys.providerKey(for: "openai"), "no other id written")
        XCTAssertEqual(saved, ["google"])
    }

    func testSaveWithBlankKeyDoesNotReportSaved() {
        let keys = InMemoryProviderKeyStore()
        var saved: [String] = []
        RoutePicker.KeyOnly.save("  ", for: "google", in: keys) { saved.append($0) }
        XCTAssertEqual(saved, [], "a sheet that closes on a blank save narrates a key that is not there")
        XCTAssertNil(keys.providerKey(for: "google"))
    }

    // MARK: - Source census: one write site, no route commit in key-only

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

    /// Both CTAs reach the keychain through `storeKey`, the one place that
    /// calls `keys.setProviderKey(`; and `KeyOnly` has no route commit at all.
    func testKeyOnlyHasNoRouteCommitAndBothCTAsShareTheOneWriter() throws {
        let code = try codeLines("RoutePicker.swift")
        guard let start = code.firstIndex(where: { $0.contains("struct KeyOnly: View") }) else {
            return XCTFail("VOID: KeyOnly is not in RoutePicker.swift")
        }
        let keyOnly = code[start...]
        let routes = code[..<start]

        // POS controls: the walk sees both halves.
        XCTAssertTrue(routes.contains { $0.contains("onCommit(id, typed, baseURLText)") },
                      "POS control: the route CTA's commit is in the first half")
        XCTAssertTrue(keyOnly.contains { $0.contains("RoutePicker.storeKey(") },
                      "KeyOnly must save through the shared helper")

        for needle in ["onCommit", "recordRoutesChoice", "store.save", "keys.setProviderKey("] {
            XCTAssertEqual(keyOnly.filter { $0.contains(needle) }.count, 0,
                           "key-only mode must not reach `\(needle)`")
        }
        XCTAssertEqual(routes.filter { $0.contains("Self.storeKey(keyText, for: id, in: keys)") }.count, 1,
                       "the route CTA writes through the same helper")
        XCTAssertEqual(code.filter { $0.contains("keys.setProviderKey(") }.count, 1,
                       "exactly one keychain write site in the file")
    }
}
