import XCTest
@testable import Zeus

/// Cold-start restore.
///
/// The defect these guard is not a crash and not a wrong value on screen: it
/// is the app *forgetting* a completed commissioning across a process
/// boundary, which produces a correct-looking splash screen and no error at
/// all. Nothing in the type system objects to `@State` losing its value —
/// that is what `@State` is for — so the only instrument that can see this is
/// a test that constructs a **second** `AppState` over the same store.
@MainActor
final class CommissionStoreTests: XCTestCase {

    /// A `UserDefaults` suite unique to each test, removed on teardown.
    ///
    /// Not `.standard`: a test writing there mutates the simulator's real
    /// preference domain, survives the process, and leaks into every later
    /// test — the same reasoning that keeps `GatewayConfig.resolve(from:)`
    /// taking its environment as a parameter rather than reading `ProcessInfo`.
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.zeus.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> UserDefaultsCommissionStore {
        UserDefaultsCommissionStore(defaults: defaults)
    }

    // MARK: - Round trip

    /// VACUITY FLOOR for every test below: an untouched store reads `nil`.
    ///
    /// Without this, a store that returned `nil` unconditionally would pass
    /// the "clear" test and fail nothing — and a store that returned a
    /// default `Commission()` would make the restore assertions look like
    /// they were reading a real record when they were reading a constant.
    func testEmptyStoreLoadsNil() {
        XCTAssertNil(makeStore().load())
    }

    func testSaveThenLoadRoundTripsEveryField() {
        let store = makeStore()
        let written = Commission(route: .byok, callsign: "MIGUEL", nodeEnrolled: true)
        store.save(written)

        let read = store.load()
        XCTAssertEqual(read, written)
        // Field-wise as well as whole-value: `Equatable` on a struct with a
        // field the encoder silently dropped would still compare equal if the
        // decoder defaulted it the same way on both sides.
        XCTAssertEqual(read?.route, .byok)
        XCTAssertEqual(read?.callsign, "MIGUEL")
        XCTAssertEqual(read?.nodeEnrolled, true)
    }

    /// The two non-default field values are asserted to actually DIFFER from
    /// a fresh `Commission()`, so the round-trip above cannot be satisfied by
    /// a decoder that ignores the payload and returns defaults.
    /// VACUITY FLOOR — and it did its job during the MANAGED cut: the fixture
    /// used to differ from the default on `route` (`.managed` vs `.byok`), and
    /// when the default flipped to `.byok` the two collapsed. This test failed
    /// and every round-trip test above it kept passing, because a round-trip of
    /// the default value round-trips whatever the encoder does.
    ///
    /// `route` no longer discriminates and cannot: `.managed` is decode-only
    /// (Commissioning.swift:120), so a fixture that used it would assert on a
    /// value the app cannot produce. The discriminating fields are now
    /// `provider`, `callsign` and `nodeEnrolled`, and each is asserted
    /// separately so a partial collapse fails here rather than silently
    /// weakening the suite.
    func testRoundTripFixtureDiffersFromDefault() {
        let fresh = Commission()
        let written = Commission(route: .byok, provider: "ollama", callsign: "MIGUEL", nodeEnrolled: true)
        XCTAssertNotEqual(fresh, written)
        XCTAssertNotEqual(fresh.provider, written.provider)
        XCTAssertNotEqual(fresh.callsign, written.callsign)
        XCTAssertNotEqual(fresh.nodeEnrolled, written.nodeEnrolled)
    }

    func testSaveOverwritesPreviousValue() {
        let store = makeStore()
        store.save(Commission(route: .byok, callsign: "FIRST", nodeEnrolled: false))
        store.save(Commission(route: .byok, callsign: "SECOND", nodeEnrolled: true))
        XCTAssertEqual(store.load()?.callsign, "SECOND")
    }

    func testClearForgets() {
        let store = makeStore()
        store.save(Commission(route: .byok, callsign: "X", nodeEnrolled: false))
        XCTAssertNotNil(store.load(), "vacuity floor: there was something to clear")
        store.clear()
        XCTAssertNil(store.load())
    }

    /// A corrupted blob reads as "no commission" and is removed — not a
    /// crash, and not a default-constructed value that would silently skip
    /// commissioning for an operator who never did it.
    func testCorruptPayloadLoadsNilAndSelfHeals() {
        defaults.set(Data("not json".utf8), forKey: UserDefaultsCommissionStore.key)
        let store = makeStore()
        XCTAssertNil(store.load())
        XCTAssertNil(defaults.data(forKey: UserDefaultsCommissionStore.key),
                     "the undecodable record is removed rather than re-read every launch")
    }

    // MARK: - Cold start, across two AppState instances

    /// THE POINT OF THE FILE.
    ///
    /// Two `AppState` instances over one store stands in for two app
    /// lifetimes. A single instance would pass trivially — it would be
    /// reading the field it just wrote — which is exactly the shape the
    /// `@State` version had and exactly why it went unnoticed.
    func testCommissionSurvivesIntoAFreshAppState() {
        let store = makeStore()

        let first = AppState(store: store)
        XCTAssertNil(first.commission, "vacuity floor: launch one is uncommissioned")
        first.commission(Commission(route: .byok, callsign: "MIGUEL", nodeEnrolled: true))
        XCTAssertNotNil(first.commission)

        let second = AppState(store: store)
        XCTAssertEqual(second.commission?.callsign, "MIGUEL")
        XCTAssertEqual(second.commission?.route, .byok)
        XCTAssertEqual(second.commission?.nodeEnrolled, true)
    }

    /// The negative arm, and it is not redundant with the floor above: it
    /// proves a *decommission* also crosses the boundary. A store that only
    /// ever appended would pass the restore test and fail this one.
    func testDecommissionSurvivesIntoAFreshAppState() {
        let store = makeStore()

        let first = AppState(store: store)
        first.commission(Commission(route: .byok, callsign: "MIGUEL", nodeEnrolled: false))
        XCTAssertNotNil(AppState(store: store).commission,
                        "vacuity floor: it was restorable before the revoke")

        first.decommission()
        XCTAssertNil(first.commission)
        XCTAssertNil(AppState(store: store).commission)
    }

    /// Persist-before-publish: the store holds the value at the instant the
    /// published property changes, so a crash in the same turn as the
    /// transition cannot strand the operator on a console that will be gone.
    func testCommissionWritesStoreBeforePublishing() {
        let store = makeStore()
        let state = AppState(store: store)
        state.commission(Commission(route: .byok, callsign: "ORDER", nodeEnrolled: false))
        XCTAssertEqual(store.load()?.callsign, "ORDER")
        XCTAssertEqual(state.commission?.callsign, "ORDER")
    }

    // MARK: - In-memory store

    func testInMemoryStoreSeedsAndClears() {
        let seeded = InMemoryCommissionStore(seed: Commission(route: .byok, callsign: "S", nodeEnrolled: true))
        XCTAssertEqual(seeded.load()?.callsign, "S")
        seeded.clear()
        XCTAssertNil(seeded.load())
    }

    /// The in-memory store must NOT reach `UserDefaults` — a screenshot run
    /// seeding a commission cannot be allowed to change what a later
    /// unargumented launch photographs.
    func testInMemoryStoreDoesNotTouchUserDefaults() {
        let memory = InMemoryCommissionStore()
        memory.save(Commission(route: .byok, callsign: "GHOST", nodeEnrolled: true))
        XCTAssertNil(defaults.data(forKey: UserDefaultsCommissionStore.key))
        XCTAssertNil(UserDefaults.standard.data(forKey: UserDefaultsCommissionStore.key),
                     "and not the standard domain either")
    }
}

// MARK: - MANAGED deferral (ruled 2026-09-07)

/// The three sites the MANAGED ruling reaches, guarded at the value.
///
/// APERTURE: these assert the MODEL — the decodable case, the summary string,
/// the seed. They say nothing about whether the routes step renders one card
/// or two; a SwiftUI body is not observable in this target. The card's absence
/// is guarded by `testNoManagedStringSurvivesInTheRoutesStep` below, which is
/// a source grep and is honest about being one.
final class ManagedDeferralTests: XCTestCase {

    /// (1) An install that persisted `managed` must DECODE, not re-onboard.
    func testAPersistedManagedRecordStillDecodes() throws {
        let legacy = #"{"route":"managed","callsign":"MIGUEL","node_enrolled":true}"#
        let data = try XCTUnwrap(legacy.data(using: .utf8))
        let c = try JSONDecoder().decode(Commission.self, from: data)
        XCTAssertEqual(c.route, .managed, "the case must survive as a decodable value")
        XCTAssertEqual(c.callsign, "MIGUEL")
        XCTAssertTrue(c.nodeEnrolled)
    }

    /// The migration leg: the record predates `provider` and has no such key.
    /// Swift's SYNTHESISED decoder throws `keyNotFound` here — which
    /// `CommissionStore.load` turns into nil — so this test dies if the
    /// hand-written `init(from:)` is deleted in favour of synthesis.
    func testALegacyRecordWithoutProviderDecodesToNilAndSaysSo() throws {
        let legacy = #"{"route":"byok","callsign":"ATLAS","node_enrolled":false}"#
        let data = try XCTUnwrap(legacy.data(using: .utf8))
        let c = try JSONDecoder().decode(Commission.self, from: data)
        XCTAssertNil(c.provider, "a missing new key must not erase the record — and must not invent a value")
        // The screen is the point: nil must SAY not-set, never name a provider
        // the operator did not choose.
        XCTAssertTrue(c.summary.contains("NO PROVIDER — SET ONE IN ROUTES"), c.summary)
        XCTAssertFalse(c.summary.uppercased().contains("ANTHROPIC"),
                       "a record that never set a provider must not print one: \(c.summary)")
    }

    /// THE WRITER. `provider` is nil until an operator action names one, so
    /// the routes step must WRITE it — a fresh commission that reached `done`
    /// without this call would print the unset-provider marker on the summary.
    func testTheRoutesStepWritesTheProviderAndTheRouteTogether() {
        var c = Commission()
        XCTAssertNil(c.provider, "nothing has chosen yet")
        XCTAssertTrue(c.summary.contains("NO PROVIDER — SET ONE IN ROUTES"), c.summary)

        c.recordRoutesChoice()

        XCTAssertEqual(c.route, .byok)
        XCTAssertEqual(c.provider, Commission.routesProviderID)
        XCTAssertTrue(c.summary.contains("ANTHROPIC · OWN KEY"), c.summary)
        XCTAssertFalse(c.summary.contains("NO PROVIDER — SET ONE IN ROUTES"), c.summary)
    }

    /// APERTURE, STATED: the function above is guarded; the ONE LINE that calls
    /// it inside the CTA closure is not — a SwiftUI body is not observable in
    /// this target (no ViewInspector). Deleting that line left the whole suite
    /// green before this grep existed. A source grep is a weaker instrument
    /// than a test, and it is named as one.
    func testTheRoutesCTACallsTheWriter() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Commissioning.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("mutating func recordRoutesChoice"),
                      "POS control: the grep is reading the right file")
        XCTAssertTrue(src.contains("commission.recordRoutesChoice()"),
                      "the routes CTA must write the choice, not leave provider nil")
    }

    /// THE DEFAULT MUST NOT CREEP BACK, and this is the leg that says so in a
    /// form a grep can hold: `Commissioning.swift` may name a provider in
    /// exactly ONE place — `routesProviderID`, the constant of the routes step,
    /// reachable only by an operator action. Any second occurrence is either a
    /// decoder default (the fabrication this commit removed) or a comment
    /// quoting the literal, which is the self-match that tripped this file
    /// three times: the guard cannot tell them apart, so the file carries none.
    /// The count is the invariant, not the absence.
    func testCommissioningNamesAProviderInExactlyOnePlace() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Commissioning.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("static let routesProviderID"),
                      "POS control: the grep is reading the right file")
        let literal = "\"" + Commission.routesProviderID + "\""
        let hits = src.components(separatedBy: literal).count - 1
        XCTAssertEqual(hits, 1,
                       """
                       exactly one site may name a provider literal. Found \(hits). \
                       A second is either a decoder default — nil means nobody chose — \
                       or a comment quoting the literal, and this guard cannot tell \
                       them apart. Cite the shape, not the string.
                       """)
    }

    /// POSITIVE CONTROL for the leg above: the same decoder, same store shape,
    /// WITH the key present — so the nil result is a property of the absent
    /// key and not of a decoder that drops the field on every input.
    func testARecordThatHeldAProviderStillDecodesIt() throws {
        let record = #"{"route":"byok","provider":"ollama","callsign":"ATLAS","node_enrolled":false}"#
        let data = try XCTUnwrap(record.data(using: .utf8))
        let c = try JSONDecoder().decode(Commission.self, from: data)
        XCTAssertEqual(c.provider, "ollama")
        XCTAssertTrue(c.summary.contains("OLLAMA · OWN KEY"), c.summary)
    }

    /// And the whole path, through the store the app actually uses — the
    /// value-level decode above proves the type, not the loader.
    func testTheStoreLoadsALegacyManagedRecordRatherThanReturningNil() throws {
        let suite = "test.managed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = #"{"route":"managed","callsign":"MIGUEL","node_enrolled":true}"#
        defaults.set(legacy.data(using: .utf8), forKey: "com.zeus.commission.v1")

        let loaded = UserDefaultsCommissionStore(defaults: defaults).load()
        XCTAssertNotNil(loaded, "a legacy managed record must not send the operator back through onboarding")
        XCTAssertEqual(loaded?.route, .managed)
    }

    /// (2) The summary prints a value something wrote, not a route count.
    func testSummaryNamesTheProviderAndNeverAFabricatedRouteCount() {
        let c = Commission(route: .byok, provider: "anthropic", callsign: "MIGUEL", nodeEnrolled: false)
        XCTAssertTrue(c.summary.contains("ANTHROPIC · OWN KEY"), "summary must name the provider set at routes: \(c.summary)")
        XCTAssertFalse(c.summary.contains("11 routes"), "no route count: nothing measured one")
        XCTAssertFalse(c.summary.lowercased().contains("managed"), "summary must not print a mode the app cannot produce")
    }

    /// DISCRIMINATION: two different providers must produce two different
    /// summaries, or the field is decorative and the assertion above passes
    /// on a hardcoded string.
    func testSummaryVariesWithTheProvider() {
        let a = Commission(provider: "anthropic", callsign: "X").summary
        let b = Commission(provider: "ollama", callsign: "X").summary
        XCTAssertNotEqual(a, b, "summary must be derived from `provider`, not fixed")
        XCTAssertTrue(b.contains("OLLAMA · OWN KEY"), b)
    }

    /// (3) The capture seed is a mode that exists, and its provider id is one
    /// the CORE accepts — asserted against the same prefix list the bridge
    /// routes through, so a typo here fails the build rather than shipping a
    /// screenshot of a state the core would refuse on the first send.
    func testTheCaptureSeedIsByokWithACoreAcceptedProvider() throws {
        #if DEBUG
        // READS THE SHIPPING CONSTANT, not a reconstruction of it. A local
        // `Commission(...)` literal here survived the mutation that flips the
        // real seed back to `.managed` — measured, not assumed.
        let seeded = LaunchArgs.captureSeed
        XCTAssertEqual(seeded.route, .byok)
        XCTAssertFalse(seeded.summary.lowercased().contains("managed"),
                       "the captured summary frame must not carry the string `managed`: \(seeded.summary)")
        XCTAssertTrue(seeded.summary.contains("ANTHROPIC · OWN KEY"), seeded.summary)
        // The id must be one `Provider::from_prefix` knows (zeus-core:8922).
        let coreAccepted = ["anthropic", "openai", "ollama", "openrouter", "google", "gemini",
                            "groq", "mistral", "together", "fireworks", "azure", "bedrock",
                            "deepseek", "xai", "grok", "cerebras", "moonshot", "kimi"]
        let seededProvider = try XCTUnwrap(seeded.provider,
                                           "the capture seed must WRITE a provider, not inherit one")
        XCTAssertTrue(coreAccepted.contains(seededProvider),
                      "`\(seededProvider)` is not a prefix the core resolves")
        #endif
    }

    /// The card is gone from the shipping source. A GREP, and named as one:
    /// it proves the string is absent from the routes step, not that the view
    /// renders one card. POS control in the same read.
    func testNoManagedCardStringSurvivesInTheShippingSource() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Commissioning.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("YOUR OWN KEYS"), "POS control: the grep can find a card title")
        XCTAssertFalse(src.contains("MANAGED — NOVA CREDITS"), "the MANAGED card must not render")
        XCTAssertFalse(src.contains("11 routes, zero keys"), "its copy must go with it")
        XCTAssertFalse(src.contains("Pick how I reach the models"),
                       "one option is not a pick — the narration must not offer a choice")
    }
}

// MARK: - ZM's copy register: the retired strings, and the caption's gate

/// Two legs for the copy commit, both about strings that must read ZERO in
/// the shipping source — and a zero is the reading a DEAD WALK produces too.
/// Every leg here therefore carries a control proving the walk saw the file.
final class CopyRegisterTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Code lines only. A retired string pasted into a comment as an
    /// explanation is exactly the defect `Commissioning.swift:44` warns
    /// about, and a comment-blind grep cannot tell the two apart.
    private func codeLines(_ src: String) -> [String] {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// S3. The rendered noun is singular — a state, one key. `BYOK` survives
    /// in `Sources` only as prose (4 comment lines at the time of writing);
    /// this leg scopes to RENDERABLE strings, so a comment explaining the
    /// history cannot fail it and a re-introduced literal cannot pass it.
    /// POS is the replacement in the same walk: a zero on the old noun means
    /// removal only if the walk demonstrably reads the new one.
    func testTheRenderedRouteNounIsSingularAndTheOldOneIsGone() throws {
        let code = codeLines(try source("Commissioning.swift"))
        XCTAssertEqual(code.filter { $0.contains("· OWN KEY") }.count, 1,
                       "POS: the walk reads the REPLACEMENT — a dead walk VOIDs instead of greening the count")
        XCTAssertEqual(code.filter { $0.contains("· BYOK") }.count, 0,
                       "the retired noun must not ship in a rendered string")
        // The rendered value itself, not just the source line.
        let c = Commission(route: .byok, provider: "anthropic", callsign: "ATLAS", nodeEnrolled: false)
        XCTAssertTrue(c.summary.contains("ANTHROPIC · OWN KEY"), c.summary)
        XCTAssertFalse(c.summary.contains("BYOK"), c.summary)
    }

    /// S1. `PROVIDER NOT SET` is retired in favour of
    /// `NO PROVIDER — SET ONE IN ROUTES`. The POS is the replacement: a zero
    /// on the old string only means removal if the same walk can find the
    /// new one in the same file.
    func testRetiredUnsetProviderStringIsGoneFromTheSource() throws {
        let src = try source("Commissioning.swift")
        let code = codeLines(src)
        XCTAssertEqual(code.filter { $0.contains("NO PROVIDER — SET ONE IN ROUTES") }.count, 1,
                       "POS: the walk reads the REPLACEMENT — without this a dead walk passes")
        XCTAssertEqual(code.filter { $0.contains("PROVIDER NOT SET") }.count, 0,
                       "the retired unset-provider marker must not ship")
    }

    /// E3, gated. The old SAVE caption named the work that would enable the
    /// disabled half; ZM's rule is that a disabled control states what it
    /// DOES, never what is coming. The new caption is honest ONLY while the
    /// URL half really is read-only — so a zero-count on the old string is
    /// uninformative until the wiring exists.
    ///
    /// POS-A is the wiring census: does `GatewayEditor` write
    /// `Commission.gatewayURL` yet? Today it does not (the editor holds no
    /// `store` at all — the four `store` mentions in that file are prose,
    /// including a `WRITES` docstring describing a write that does not
    /// exist). While POS-A reads 0 this leg VOIDs rather than passing: a
    /// pass before ③c would be a pass for the wrong reason.
    func testSaveCaptionIsHonestAboutWhatTheButtonWrites() throws {
        let src = try source("GatewayEditor.swift")
        let code = codeLines(src)

        // POS-B: the comment-stripped walk is live. A known-present code
        // needle, so a filter bug VOIDs instead of greening every count.
        XCTAssertGreaterThan(code.filter { $0.contains("tokens.") }.count, 0,
                             "VOID: the comment-stripped walk read nothing")

        // POS-A: the URL-write wiring, code lines only.
        let writesURL = code.filter {
            $0.contains("gatewayURL") && ($0.contains("store") || $0.contains("save"))
        }.count

        guard writesURL > 0 else {
            // Not a failure — an honest abstention. The caption's truth
            // value is undefined until the wiring lands (③c), and the
            // current caption states exactly the state measured here.
            XCTAssertEqual(code.filter { $0.contains("TOKEN SAVES NOW — URL IS READ-ONLY IN THIS BUILD") }.count, 1,
                           "while the URL half is unwired the caption must say so")
            XCTAssertEqual(code.filter { $0.contains("URL SAVES WHEN COMMISSION WIRING LANDS") }.count, 0,
                           "the retired caption named future work — ZM's rule, and it must not ship")
            return
        }

        // ③c has landed: the URL half writes, so the read-only caption is
        // now itself a lie and must be gone.
        XCTAssertEqual(code.filter { $0.contains("URL IS READ-ONLY IN THIS BUILD") }.count, 0,
                       "the editor writes the URL now — the read-only caption is stale")
    }
}
