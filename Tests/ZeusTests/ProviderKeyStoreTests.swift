import XCTest
@testable import Zeus

/// The provider-key store, and the wiring that makes it reachable.
///
/// Every value leg runs against `InMemoryProviderKeyStore`: the simulator's
/// Keychain PERSISTS ACROSS RUNS, so a "two ids, two keys" leg against the
/// real store would pass on residue from an earlier run and keep passing
/// after the writer was deleted.
final class ProviderKeyStoreTests: XCTestCase {

    // MARK: - Value semantics

    func testRoundTrip() {
        let keys = InMemoryProviderKeyStore()
        keys.setProviderKey("sk-ant-abc", for: "anthropic")
        XCTAssertEqual(keys.providerKey(for: "anthropic"), "sk-ant-abc")
    }

    func testAbsentIsNil() {
        let keys = InMemoryProviderKeyStore()
        XCTAssertNil(keys.providerKey(for: "anthropic"),
                     "an unwritten provider must answer nil, not empty string: "
                     + "`\"\"` would arm the core with a key it cannot use")
        keys.setProviderKey("k", for: "openai")
        XCTAssertNil(keys.providerKey(for: "anthropic"),
                     "writing one id must not make another id present")
    }

    func testTwoIdsTwoKeysNoBleed() {
        let keys = InMemoryProviderKeyStore()
        keys.setProviderKey("sk-ant", for: "anthropic")
        keys.setProviderKey("sk-oai", for: "openai")
        XCTAssertEqual(keys.providerKey(for: "anthropic"), "sk-ant")
        XCTAssertEqual(keys.providerKey(for: "openai"), "sk-oai")
        // Vacuity: the two legs above pass on a store that returns one
        // constant if the fixtures happen to be equal. They are not.
        XCTAssertNotEqual(keys.providerKey(for: "anthropic"),
                          keys.providerKey(for: "openai"),
                          "VOID: the fixtures are equal, so no-bleed is untested")
    }

    func testUpsertReplaces() {
        let keys = InMemoryProviderKeyStore()
        keys.setProviderKey("old", for: "anthropic")
        keys.setProviderKey("new", for: "anthropic")
        XCTAssertEqual(keys.providerKey(for: "anthropic"), "new",
                       "re-entering a key for the same provider must REPLACE; "
                       + "an append or a first-write-wins leaves the operator "
                       + "unable to correct a typo")
    }

    func testRemoveClears() {
        let keys = InMemoryProviderKeyStore()
        keys.setProviderKey("sk", for: "anthropic")
        keys.setProviderKey("other", for: "openai")
        keys.removeProviderKey(for: "anthropic")
        XCTAssertNil(keys.providerKey(for: "anthropic"))
        XCTAssertEqual(keys.providerKey(for: "openai"), "other",
                       "remove must be scoped to one id, not a wipe")
    }

    // MARK: - The secret is not in the record, and not in UserDefaults

    func testTheKeyIsNeverInTheCommissionRecord() throws {
        var c = Commission()
        c.recordRoutesChoice(providerID: "anthropic", model: "claude-sonnet-4-6")
        let blob = try JSONEncoder().encode(c)
        let json = String(data: blob, encoding: .utf8) ?? ""

        // POS control, same invocation: a field known to be in the record.
        XCTAssertTrue(json.contains("anthropic"),
                      "VOID: the encoder produced no provider field, so the "
                      + "absence below is a statement about the encoder")

        for needle in ["providerKey", "apiKey", "secret", "keyText"] {
            XCTAssertFalse(json.contains(needle),
                           "the commission rides in UserDefaults precisely because "
                           + "it carries no secret; `\(needle)` in the blob breaks that")
        }
    }

    func testTheKeyWriterIsTheKeychainAndNotUserDefaults() throws {
        let src = try source("Commissioning.swift")
        let code = src.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }

        let writes = code.filter { $0.contains("keys.setProviderKey(") }
        XCTAssertEqual(writes.count, 1,
                       "exactly ONE write site for the operator's key; found \(writes.count)")

        // The typed secret must not reach the record or the defaults.
        XCTAssertEqual(code.filter { $0.contains("UserDefaults") && $0.contains("key") }.count, 0,
                       "no key may be written through UserDefaults from this flow")
        XCTAssertEqual(code.filter { $0.contains("commission.") && $0.contains("keyText") }.count, 0,
                       "the typed key must never be assigned into the commission")
    }

    // MARK: - Source-order: the store exists BEFORE the arm

    /// The guard against a quiet re-arm with `nil`.
    ///
    /// `providerKey: nil` sat at the arming call site for the life of the
    /// feature and no VALUE leg could see it — the arm returned a correct
    /// string for a wrong input. The instrument that catches it is positional:
    /// the key store must be constructed above the call that reads it.
    func testTheKeyStoreIsConstructedBeforeTheArm() throws {
        let src = try source("RootView.swift")
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }

        guard let build = lines.firstIndex(where: { $0.contains("ProviderKeyStore()") }) else {
            return XCTFail("VOID: no key-store construction in RootView — this leg measured nothing")
        }
        guard let arm = lines.firstIndex(where: { $0.contains("armedResolution(store: store, keys: keys)") }) else {
            return XCTFail("VOID: no armed-resolution call in RootView — this leg measured nothing")
        }
        XCTAssertLessThan(build, arm,
                          "the key store must be built before the arm reads it; "
                          + "line \(build) vs \(arm)")

        // And the literal that used to sit at the call site is gone.
        XCTAssertEqual(lines.filter { $0.contains("providerKey: nil") }.count, 0,
                       "`providerKey: nil` at the arming site arms every keyed "
                       + "provider to NO KEY regardless of what the operator entered")
        XCTAssertEqual(lines.filter { $0.contains("providerKey: key") }.count, 1,
                       "VOID: the arm no longer passes the read key")
    }

    /// The read is for the provider on the RECORD.
    func testTheArmReadsTheKeyForTheRecordedProvider() throws {
        let src = try source("RootView.swift")
        XCTAssertTrue(src.contains("keys.providerKey(for: $0)"),
                      "the key must be looked up by the recorded provider id")
    }

    // MARK: - The field is live, and the copy no longer says it is not

    func testTheKeyFieldIsEnterableAndMasked() throws {
        let src = try source("Commissioning.swift")
        XCTAssertTrue(src.contains("SecureField(\"\", text: $keyText"),
                      "the key field must be a SecureField: an unmasked secret is "
                      + "readable over a shoulder and offered to the keyboard cache")
        XCTAssertFalse(src.contains("KEY ENTRY ARRIVES WITH THE ON-PHONE KEY STORE"),
                       "the inert-field copy must go with the inert field; it now "
                       + "tells the operator to wait for something that has shipped")
        XCTAssertFalse(src.contains("disabledKeyField"),
                       "the disabled field is retired, not renamed")
    }

    func testSwitchingProviderClearsTheTypedKeyAndRemovesTheOld() throws {
        let src = try source("Commissioning.swift")
        XCTAssertTrue(src.contains("keys.removeProviderKey(for: previous)"),
                      "switching rows must remove the abandoned provider's key: "
                      + "a half-finished choice must not leave an orphan secret")
        XCTAssertTrue(src.contains("keyText = \"\""),
                      "switching rows must clear the field; a key typed for one "
                      + "provider is not a key for another")
    }

    func testTheKeyStoreHasNoDefaultOnTheView() throws {
        let src = try source("Commissioning.swift")
        XCTAssertTrue(src.contains("let keys: ProviderKeyStoring"),
                      "VOID: no key-store seam on the view")
        XCTAssertFalse(src.contains("keys: ProviderKeyStoring = "),
                       "no default: a default lets a caller omit the store and "
                       + "write the operator's secret into a stand-in that forgets it")
    }

    // MARK: - Key spaces do not collide

    func testTheTwoKeychainServicesAreDistinct() {
        XCTAssertNotEqual(ProviderKeyStore.service, GatewayTokenStore.service,
                          "a shared service string would let a gateway host and a "
                          + "provider id collide in one key space")
    }

    // MARK: -

    private func source(_ name: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/ZeusApp/\(name)")
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(domain: "VOID", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "VOID: no source at \(url.path)"])
        }
        return body
    }
}
