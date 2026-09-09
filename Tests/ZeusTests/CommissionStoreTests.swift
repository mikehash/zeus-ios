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
        XCTAssertTrue(c.summary.contains("no provider"), c.summary)
        XCTAssertFalse(c.summary.uppercased().contains("ANTHROPIC"),
                       "a record that never set a provider must not print one: \(c.summary)")
    }

    /// THE WRITER. `provider` is nil until an operator action names one, so
    /// the routes step must WRITE it — a fresh commission that reached `done`
    /// without this call would print the unset-provider marker on the summary.
    func testTheRoutesStepWritesTheProviderAndTheRouteTogether() {
        var c = Commission()
        XCTAssertNil(c.provider, "nothing has chosen yet")
        XCTAssertTrue(c.summary.contains("no provider"), c.summary)

        // `model` has no default: the caller must have ASKED the provider.
        // This leg names the writer's contract, not the CTA's plumbing.
        c.recordRoutesChoice(providerID: "anthropic", model: "claude-x", baseURL: nil)

        XCTAssertEqual(c.route, .byok)
        XCTAssertEqual(c.model, "claude-x")
        XCTAssertEqual(c.provider, "anthropic")
        // THE SUMMARY RENDERS THE CORE'S LABEL, NOT `id.uppercased()`.
        let saved = ProviderCatalog.current
        defer { ProviderCatalog.current = saved }
        ProviderCatalog.current = StubCatalog(rows: [
            ProviderRow(id: "anthropic", label: "Anthropic", shape: .key)
        ])
        XCTAssertTrue(c.summary.contains("Anthropic\u{00A0}·\u{00A0}OWN KEY"), c.summary)
        XCTAssertFalse(c.summary.contains("ANTHROPIC"), "the wire id must not be upper-cased into a display form: \(c.summary)")
        XCTAssertFalse(c.summary.contains("no provider"), c.summary)
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
        // The needle moved with the cut: the CTA now passes the model it
        // obtained from the provider, so the argument-less spelling would read
        // 0 forever. Widened to the call, not the exact argument list.
        XCTAssertTrue(src.contains("commission.recordRoutesChoice(providerID:"),
                      "the routes CTA must write the choice, not leave provider nil")
        XCTAssertTrue(src.contains("CoreArming.firstModel("),
                      "the model must come from the provider at the step, never from a literal")
    }

    /// THE FILE NAMES NO PROVIDER AT ALL, AND THE INVARIANT IS NOW ZERO.
    ///
    /// It used to be ONE — `routesProviderID`, the hardcoded id of a
    /// single-card routes step. The picker retired it: rows come from
    /// `list_providers()` and the id the operator taps is the only literal
    /// that ever reaches `provider`. Zero is a STRONGER invariant than one and
    /// it needed the POS control re-anchored, because a guard whose subject is
    /// deleted stops asserting silently rather than loudly.
    func testCommissioningNamesNoProviderLiteralAtAll() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Commissioning.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        // POS CONTROL, RE-ANCHORED. The old control asserted the CONSTANT
        // exists — retiring the constant would have left this guard asserting
        // about a thing that no longer exists, which fails silently rather
        // than loudly. It now anchors on the step that does the writing.
        XCTAssertTrue(src.contains("func recordRoutesChoice"),
                      "POS control: the grep is reading the right file")
        let literal = "\"anthropic\""
        let hits = src.components(separatedBy: literal).count - 1
        XCTAssertEqual(hits, 0,
                       """
                       shipping source may name NO provider literal. Found \(hits). \
                       Any hit is a decoder default, a step constant, or a comment \
                       quoting one, and this guard cannot tell them apart. \
                       Cite the shape, not the string.
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
        XCTAssertTrue(c.summary.contains("Ollama\u{00A0}·\u{00A0}OWN KEY"), c.summary)
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
        XCTAssertTrue(c.summary.contains("Anthropic\u{00A0}·\u{00A0}OWN KEY"), "summary must name the provider set at routes: \(c.summary)")
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
        XCTAssertTrue(b.contains("Ollama\u{00A0}·\u{00A0}OWN KEY"), b)
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
        XCTAssertTrue(seeded.summary.contains("Anthropic\u{00A0}·\u{00A0}OWN KEY"), seeded.summary)
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
        // POS CONTROL, RE-ANCHORED. It used to name the single BYOK card's title;
        // the picker retired that card — rows come from the core's catalog now —
        // so the control anchors on the step that renders them. A control whose
        // subject is deleted stops controlling silently.
        XCTAssertTrue(src.contains("private var routesStep"), "POS control: the grep can find the routes step")
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
        XCTAssertEqual(code.filter { $0.contains("\"OWN KEY\"") }.count, 1,
                       "POS: the walk reads the REPLACEMENT — a dead walk VOIDs instead of greening the count")
        XCTAssertEqual(code.filter { $0.contains("· BYOK") }.count, 0,
                       "the retired noun must not ship in a rendered string")
        // The rendered value itself, not just the source line.
        let c = Commission(route: .byok, provider: "anthropic", callsign: "ATLAS", nodeEnrolled: false)
        XCTAssertTrue(c.summary.contains("Anthropic\u{00A0}·\u{00A0}OWN KEY"), c.summary)
        XCTAssertFalse(c.summary.contains("BYOK"), c.summary)
    }

    /// S1. `PROVIDER NOT SET` is retired. The summary FOOTER now states the
    /// state only — `no provider` — because the repair belongs on the control
    /// that performs it, not repeated in a status strip; the full sentence
    /// `NO PROVIDER — SET ONE IN ROUTES` survives as
    /// `GatewayConfig.noProviderMessage` on the composer, which is the surface
    /// the operator is actually blocked at. The POS is the replacement: a zero
    /// on the old string only means removal if the same walk can find the
    /// new one in the same file.
    func testRetiredUnsetProviderStringIsGoneFromTheSource() throws {
        let src = try source("Commissioning.swift")
        let code = codeLines(src)
        XCTAssertEqual(code.filter { $0.contains("no provider") }.count, 1,
                       "POS: the walk reads the REPLACEMENT — without this a dead walk passes")
        XCTAssertEqual(code.filter { $0.contains("PROVIDER NOT SET") }.count, 0,
                       "the retired unset-provider marker must not ship")
    }

    /// E3, gated — and the gate FLIPPED at c1.
    ///
    /// The old SAVE caption named the work that would enable the disabled
    /// half; ZM's rule is that a disabled control states what it DOES, never
    /// what is coming. The new caption is honest ONLY while the URL half
    /// really is read-only, so a zero-count on the old string is
    /// uninformative until the wiring exists — hence POS-A.
    ///
    /// 🔴 POS-A's FIRST FORM WAS A FALSE ABSTENTION WAITING TO HAPPEN. It
    /// needled `gatewayURL` (lower-case `g`) beside `store`/`save`; the
    /// wiring that landed spells the call `recordGatewayURL(` — capital G —
    /// so the census would have read 0 against a file that writes the URL on
    /// every SAVE, and VOIDed while reporting the abstention as the honest
    /// outcome. A needle whose spelling is guessed before the code exists is
    /// a forecast, not a census. It now needles the NAMED WRITER, which is
    /// the thing the sole-writer census is about.
    func testSaveCaptionIsHonestAboutWhatTheButtonWrites() throws {
        let src = try source("GatewayEditor.swift")
        let code = codeLines(src)

        // POS-B: the comment-stripped walk is live. A known-present code
        // needle, so a filter bug VOIDs instead of greening every count.
        XCTAssertGreaterThan(code.filter { $0.contains("tokens.") }.count, 0,
                             "VOID: the comment-stripped walk read nothing")

        // POS-A: the URL-write wiring, code lines only — the named writer
        // called AND the store written, both in this file.
        let callsWriter = code.filter { $0.contains("recordGatewayURL(") }.count
        let savesStore  = code.filter { $0.contains("store.save(") }.count
        let writesURL = min(callsWriter, savesStore)

        guard writesURL > 0 else {
            // Not a failure — an honest abstention. The caption's truth
            // value is undefined until the wiring lands, and the caption
            // then in place states exactly the state measured here.
            XCTAssertEqual(code.filter { $0.contains("TOKEN SAVES NOW — URL IS READ-ONLY IN THIS BUILD") }.count, 1,
                           "while the URL half is unwired the caption must say so")
            XCTAssertEqual(code.filter { $0.contains("URL SAVES WHEN COMMISSION WIRING LANDS") }.count, 0,
                           "the retired caption named future work — ZM's rule, and it must not ship")
            return
        }

        // c1 has landed: the URL half writes, so the read-only caption is
        // now itself a lie and must be gone.
        XCTAssertEqual(code.filter { $0.contains("URL IS READ-ONLY IN THIS BUILD") }.count, 0,
                       "the editor writes the URL now — the read-only caption is stale")
        XCTAssertEqual(code.filter { $0.contains("URL SAVES WHEN COMMISSION WIRING LANDS") }.count, 0,
                       "the retired caption named future work — ZM's rule, and it must not ship")
    }

    /// THE c1 STRING, WRITTEN LIKE E3 — true now, false at c2.
    ///
    /// c1 persists a URL the running session does not follow: `resolution`
    /// is computed once in `RootView.init` and the transport is built once
    /// inside `StateObject(wrappedValue:)`, so a saved URL is read at the
    /// NEXT launch and not before. `APPLIES ON NEXT LAUNCH` is therefore the
    /// honest register — and it becomes a lie the moment c2 lands.
    ///
    /// The gate is the substrate fact the string depends on: `resolution`
    /// held as `private let`. When c2 makes it `@State` and the engine
    /// follows a re-resolved endpoint, this leg demands the string be gone
    /// rather than merely permitting it — the same self-flipping shape as
    /// E3, in the opposite direction.
    func testTheNextLaunchCaveatIsPresentExactlyWhileItIsTrue() throws {
        let editor = codeLines(try source("GatewayEditor.swift"))
        let root   = codeLines(try source("RootView.swift"))

        // POS: both walks are live.
        XCTAssertGreaterThan(editor.filter { $0.contains("store.") }.count, 0,
                             "VOID: the editor walk read nothing")
        XCTAssertGreaterThan(root.filter { $0.contains("resolution") }.count, 0,
                             "VOID: the RootView walk read nothing")

        // The gate is the LAUNCH-FROZEN resolution property. c2 deleted it —
        // `RootView` now holds a `GatewayConfigSource` the four surfaces
        // observe — so this arm flips itself rather than waiting to be
        // remembered. The needle is the STORED property, not the local in
        // `init`: the local still exists (it seeds the source) and matching it
        // would pin the caveat forever.
        let resolvedOnce = root.filter {
            $0.contains("private let resolution: GatewayConfig.Resolution")
        }.count

        let caveat = editor.filter { $0.contains("APPLIES ON NEXT LAUNCH") }.count

        if resolvedOnce > 0 {
            XCTAssertGreaterThan(caveat, 0,
                                 "the engine still resolves once per launch — SAVE must say so")
        } else {
            XCTAssertEqual(caveat, 0,
                           "c2 landed: the engine follows a saved URL, so the caveat is a lie")
        }
    }

    // MARK: - (f) the strip counts no node it cannot name

    /// VALUE leg. The summary reads `solo` WHATEVER the Bool says.
    ///
    /// Two records differing ONLY in `nodeEnrolled` must produce the same
    /// strip. The vacuity assert is required: two equal fixtures would pass
    /// this while testing nothing.
    func testTheSummaryStripReadsSoloRegardlessOfTheEnrolledBool() {
        let solo = Commission(route: .byok, provider: "anthropic",
                              callsign: "ATLAS", nodeEnrolled: false)
        let claimed = Commission(route: .byok, provider: "anthropic",
                                 callsign: "ATLAS", nodeEnrolled: true)
        XCTAssertNotEqual(solo, claimed,
                          "vacuity: the two fixtures must differ, or this leg compares a value to itself")
        XCTAssertEqual(solo.summary, claimed.summary,
                       "the strip must not render a count the record cannot name")
        XCTAssertTrue(solo.summary.contains("solo"), solo.summary)
    }

    /// ABSENCE leg, code lines only, with its own POS control.
    ///
    /// The retired string survives in `NodesView.swift` as prose explaining
    /// the retirement — a whole-file needle would hit my own explanation,
    /// which is (c)'s `All systems nominal` fault one commit over.
    func testTheEnrolledCountIsNotRenderedAnywhereInTheShippingSource() throws {
        var hits = 0
        var control = 0
        for name in ["Commissioning.swift", "NodesView.swift", "HomeView.swift"] {
            let code = codeLines(try source(name))
            XCTAssertFalse(code.isEmpty, "\(name): the walk read nothing")
            hits += code.filter { $0.contains("node enrolled") }.count
            control += code.filter { $0.contains("Theme") }.count
        }
        XCTAssertGreaterThan(control, 0, "control: the code-line filter kept renderable lines")
        XCTAssertEqual(hits, 0, "`node enrolled` is a count nothing measures")
    }

    /// The DEBUG capture seed no longer claims a node.
    ///
    /// Read from the constant, not from a reconstructed literal: a local
    /// `Commission(...)` copy passes with the seed mutated back, which is
    /// precisely the mutation this leg exists to kill.
    func testTheCaptureSeedDoesNotClaimAnEnrolledNode() {
        #if DEBUG
        XCTAssertFalse(LaunchArgs.captureSeed.nodeEnrolled,
                       "the seed must not photograph a node no production path can enrol")
        #endif
    }

    /// THE REASON leg: nothing in the shipping source writes `true`.
    ///
    /// This is the finding the render change rests on. The value legs above
    /// are blind to it — they assert what `summary` does with the Bool, not
    /// whether anything can set it. POS control counts the `false` writers
    /// in the same read, so a zero here cannot be a dead walk.
    func testNoShippingPathEnrolsANode() throws {
        var trueWriters = 0
        var falseWriters = 0
        for name in ["Commissioning.swift", "NodesView.swift", "RootView.swift",
                     "ZeusApp.swift", "HomeView.swift"] {
            let code = codeLines(try source(name))
            XCTAssertFalse(code.isEmpty, "\(name): the walk read nothing")
            trueWriters += code.filter {
                $0.contains("nodeEnrolled = true") || $0.contains("nodeEnrolled: true")
            }.count
            falseWriters += code.filter {
                $0.contains("nodeEnrolled = false") || $0.contains("nodeEnrolled: false")
            }.count
        }
        XCTAssertGreaterThan(falseWriters, 0,
                             "control: the walk can see nodeEnrolled writers at all")
        XCTAssertEqual(trueWriters, 0,
                       "a path that enrols a node landed — the strip owes it a name, not a count")
    }
}
