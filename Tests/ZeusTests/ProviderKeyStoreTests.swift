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

    // MARK: - One store, one truth (the behavioural leg)

    /// The defect (e) retired, stated as behaviour rather than as source.
    ///
    /// Commissioning writes the key; the arm reads it. When those are two
    /// instances they agree through the KEYCHAIN — so production was fine and
    /// nothing here would have caught it — and diverge on the IN-MEMORY arm,
    /// which is the launch the capture and the tests use. This leg drives the
    /// same object through both roles and then, as its own discriminator,
    /// drives two objects and asserts the arm goes blind.
    func testOneStoreCarriesTheKeyFromCommissioningToTheArm() {
        let store = InMemoryCommissionStore(
            seed: Commission(route: .byok, provider: "anthropic", callsign: "op",
                             nodeEnrolled: false, deployment: .local,
                             gatewayURL: nil, model: "claude-sonnet-4-6"))

        // ONE store, both roles — commissioning's write, the arm's read.
        let shared = InMemoryProviderKeyStore()
        shared.setProviderKey("sk-ant-typed-at-routes", for: "anthropic")
        XCTAssertEqual(store.load()?.provider.flatMap { shared.providerKey(for: $0) },
                       "sk-ant-typed-at-routes",
                       "the arm must read the key the ROUTES step wrote")

        // TWO stores — the shipped defect. The read is nil, and the operator
        // sees NO KEY FOR Anthropic on a key they just entered.
        let commissioningSide = InMemoryProviderKeyStore()
        let armSide = InMemoryProviderKeyStore()
        commissioningSide.setProviderKey("sk-ant-typed-at-routes", for: "anthropic")
        XCTAssertNil(store.load()?.provider.flatMap { armSide.providerKey(for: $0) },
                     "VACUITY: if a second store could see the first's write, the "
                     + "shared-instance leg above proves nothing")
    }

    // MARK: - The arm cannot OWN a store

    /// The guard against a quiet re-arm with `nil`, in its stronger form.
    ///
    /// This leg was positional — the key store had to be constructed ABOVE the
    /// call that reads it. That invariant went VACUOUS the moment construction
    /// moved to `ZeusApp`: there is nothing left in `RootView.init` to be above
    /// anything, and a leg whose subject evaporates does not go red, it goes
    /// silent. Re-anchored on the property the move actually establishes —
    /// `RootView.swift` constructs NEITHER conformer, so the arm cannot own a
    /// store at all rather than merely construct it late.
    func testTheArmConstructsNoStoreOfItsOwn() throws {
        let root = codeLines(try source("RootView.swift"))
        let app = codeLines(try source("ZeusApp.swift"))

        // POS: the filter and the needles are alive somewhere.
        XCTAssertEqual(app.filter { isConstruction($0, of: .keychain) }.count, 1,
                       "VOID: no key-store construction in ZeusApp — the needle "
                       + "matches nothing and every miss below is meaningless")
        XCTAssertEqual(app.filter { isConstruction($0, of: .inMemory) }.count, 1,
                       "VOID: no in-memory twin construction in ZeusApp")
        XCTAssertFalse(root.isEmpty, "VOID: RootView.swift read as zero code lines")

        XCTAssertEqual(root.filter { isConstruction($0, of: .keychain) || isConstruction($0, of: .inMemory) }.count, 0,
                       "RootView must construct NO key store: a store built here "
                       + "is a SECOND store, and on the in-memory arm the key the "
                       + "operator typed at ROUTES lives in the other one")
        XCTAssertTrue(root.contains(where: { $0.contains("keys: ProviderKeyStoring") }),
                      "VOID: RootView.init no longer takes the store as a parameter")

        // And the literal that used to sit at the call site is gone.
        XCTAssertEqual(root.filter { $0.contains("providerKey: nil") }.count, 0,
                       "`providerKey: nil` at the arming site arms every keyed "
                       + "provider to NO KEY regardless of what the operator entered")
        XCTAssertEqual(root.filter { $0.contains("providerKey: key") }.count, 1,
                       "VOID: the arm no longer passes the read key")
    }

    /// One instance, tree-wide. `private let` on an `App` struct is a
    /// one-instance CLAIM with no compiler behind it; this is the guard.
    func testOneConstructionSitePerConformer() throws {
        let files = try sourceFiles()
        XCTAssertGreaterThan(files.count, 5, "VOID: source sweep found almost nothing")

        for conformer in Conformer.allCases {
            let sites = files.flatMap { file in
                file.code.filter { isConstruction($0, of: conformer) }.map { _ in file.name }
            }
            XCTAssertEqual(sites.count, 1,
                           "`\(conformer.rawValue)()` is constructed \(sites.count)× in \(sites) — "
                           + "two instances agree through the Keychain in production "
                           + "and are two dictionaries on the in-memory arm")
            XCTAssertEqual(sites.first, "ZeusApp.swift",
                           "the one construction must be on the object that outlives "
                           + "both arms of the `if let`")
        }
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

    /// The two conformers, as an enum rather than a string array: adding a
    /// third makes the loop below cover it or fail to compile.
    private enum Conformer: String, CaseIterable {
        case keychain = "ProviderKeyStore"
        case inMemory = "InMemoryProviderKeyStore"
    }

    /// `"InMemoryProviderKeyStore()".contains("ProviderKeyStore()")` is TRUE —
    /// the two conformers' names are in a prefix relation, so the plain
    /// substring needle counts the twin as the real store and reported 2
    /// construction sites in a file that has one of each. Two subjects sharing
    /// a spelling, the same fault as `store: store,` growing a comma at ④b.
    /// The preceding character must not be an identifier character.
    private func isConstruction(_ line: String, of conformer: Conformer) -> Bool {
        let needle = conformer.rawValue + "()"
        var idx = line.startIndex
        while let r = line.range(of: needle, range: idx ..< line.endIndex) {
            if r.lowerBound == line.startIndex { return true }
            let before = line[line.index(before: r.lowerBound)]
            if !(before.isLetter || before.isNumber || before == "_") { return true }
            idx = r.upperBound
        }
        return false
    }

    /// Comment lines stripped. A census that counts prose is a census of
    /// intentions: the tombstone recording a deletion contains the very
    /// string the leg is asserting is gone.
    private func codeLines(_ src: String) -> [String] {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
    }

    private func sourceFiles() throws -> [(name: String, code: [String])] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ZeusApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { ($0, codeLines(try source($0))) }
    }

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
