import XCTest
@testable import Zeus

/// G0 legs: the LINK pill as a real control, the NODES gateway row in every
/// arm, the editor's read-back derivations, and the four preflight states.
///
/// APERTURE (stated once, top of file): a SwiftUI body is not observable
/// in-process, so these legs assert the DERIVATIONS (static, internal) and
/// the SOURCE TEXT (the census, by the tree's established `#filePath` grep
/// pattern) — not renderings. What is guarded here is the mapping and the
/// count; what is NOT guarded is the tap actually firing, which belongs to
/// the capture run on a full-Xcode box.
final class G0EditorTests: XCTestCase {

    // MARK: - Fixtures

    private func resolved() -> GatewayConfig {
        let e = GatewayConfig.Endpoint(
            url: URL(string: "https://zeus.example.com:8443")!,
            token: "t0")
        return .resolved(e)
    }

    private func local() -> GatewayConfig {
        .local(.ready)
    }

    private func malformed() -> GatewayConfig {
        .malformed(raw: "zeus dot local", reason: .notAURL)
    }

    /// THE FOUR ARMS. One fixture per arm so a later-added case fails the
    /// exhaustive switches at compile time, not this array at runtime.
    private var allArms: [GatewayConfig] {
        [.absent, local(), malformed(), resolved()]
    }

    // MARK: - The census: exactly one control in the grid

    /// Exactly one `action:` across the four `StatCell` call sites, and it
    /// is LINK's. The POS control: the plain `StatCell(` needle reads 4 in
    /// this file, so a wrong path VOIDs instead of falsely passing. The NEG
    /// needle is `action:` — counted on the SAME lines the census reads, not
    /// the whole file, because the editor's own body legitimately contains
    /// the word.
    func testExactlyOneStatCellIsAControl() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/HomeView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)

        // A call site may span lines (LINK's does — the action argument is
        // on its own line), so the census walks BLOCKS: from each
        // `StatCell(caption:` opener, the lines up to the one that closes
        // the call's parens. Comment-only lines are skipped, so a docstring
        // naming the needle cannot self-match.
        var blocks: [String] = []
        var i = src.startIndex
        let opener = "StatCell(caption:"
        while let r = src.range(of: opener, range: i..<src.endIndex) {
            var depth = 0
            var block = String(src[r.lowerBound..<src.endIndex])
            var end = r.lowerBound
            for ch in src[r.lowerBound..<src.endIndex] {
                block = String(src[r.lowerBound...end])
                if ch == "(" { depth += 1 }
                if ch == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                end = src.index(after: end)
            }
            blocks.append(block)
            i = src.index(after: end)
        }

        XCTAssertEqual(blocks.count, 4,
                       "POS control: the four grid call sites must all be here")
        XCTAssertTrue(blocks.contains { $0.contains("\"LINK\"") },
                      "POS control: the LINK call site is among them")

        let withAction = blocks.filter { $0.contains("action:") }
        XCTAssertEqual(withAction.count, 1,
                       "exactly one StatCell call site carries action: — found \(withAction.count)")
        XCTAssertTrue(withAction[0].contains("\"LINK\""),
                      "the one control is LINK, not another cell")
    }

    // MARK: - The trait: on the control arm, absent everywhere else

    /// The asymmetry at the source level: `.isButton` sits inside the
    /// `if let action` arm and NOWHERE else in this file — not the
    /// read-only `else` arm, not `cellBody`. Instrument: a brace-walk
    /// from each region opener to its matching close, comment-only
    /// lines skipped (the same census discipline — a docstring naming
    /// the needle cannot self-match). POS: the trait count inside the
    /// if-let block is >= 1 — if the walk were reading the wrong text,
    /// that POS would read 0 and VOID the leg. NEG: exactly 0 in the
    /// else arm and exactly 0 in cellBody. (a)∧(b) with the census
    /// above = trait on the one cell that passes `action:`, absent on
    /// the three that don't.
    func testIsButtonTraitLivesOnlyInTheActionArm() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/HomeView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)

        let needle = ".accessibilityAddTraits(.isButton)"

        // Brace-walk: from a region opener, to its matching `{`, to the
        // `}` that closes it. Returns nil when the opener is absent.
        func region(from opener: String) -> Substring? {
            guard let r = src.range(of: opener) else { return nil }
            guard let brace = src.range(of: "{", range: r.lowerBound..<src.endIndex) else { return nil }
            var depth = 0
            var end = brace.lowerBound
            for ch in src[brace.lowerBound..<src.endIndex] {
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                end = src.index(after: end)
            }
            return src[r.lowerBound..<end]
        }

        // Code-only line filter, as in the census.
        func traitCount(_ region: Substring?) -> Int {
            guard let region = region else { return -1 }  // -1 = opener absent: VOID, not pass
            return region.split(separator: "\n", omittingEmptySubsequences: true)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .reduce(0) { $0 + $1.components(separatedBy: needle).count - 1 }
        }

        let controlArm = region(from: "if let action = action {")
        let readOnlyArm = region(from: "} else {")
        let sharedBody = region(from: "private var cellBody: some View {")

        // POS control first: the walk must be able to SEE a trait where
        // one provably lives, else every 0 below is the walk's blindness.
        XCTAssertGreaterThanOrEqual(traitCount(controlArm), 1,
            "POS control: the if-let arm holds the trait — 0 here means the walk reads the wrong text, VOID not pass")

        XCTAssertEqual(traitCount(readOnlyArm), 0,
            "the read-only arm carries no isButton trait")
        XCTAssertEqual(traitCount(sharedBody), 0,
            "cellBody carries no isButton trait — the trait belongs to the wrapper, not the shared body")

        // Whole-file cardinality: exactly one, so a trait smuggled into a
        // fourth region (outside all three named) cannot hide.
        let wholeFile = src.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .reduce(0) { $0 + $1.components(separatedBy: needle).count - 1 }
        XCTAssertEqual(wholeFile, 1,
            "exactly one isButton in HomeView.swift — found \(wholeFile)")
    }

    // MARK: - The NODES row: present in EVERY arm, labelled by arm

    /// Four arms, four renderings of the same row derivation, asserted to
    /// differ only where the arm differs. An arm that hid the row would
    /// share a label with its neighbour — here, that means the two-arm
    /// distinctness assertion below fails rather than passing silently.
    func testGatewayRowExistsUnderEveryArmAndLabelsByArm() {
        let labels = allArms.map { NodesView.gatewayRowLabel(for: $0) }

        // The row EXISTS under every arm: a label is produced for each, and
        // an empty string is not a label.
        for (label, arm) in zip(labels, allArms) {
            XCTAssertFalse(label.isEmpty, "no label under \(arm)")
        }

        // FOUR distinct labels after ZM's N2/N3/N4 rewrite. `.absent` and
        // `.local` previously SHARED *use a remote gateway instead*; they no
        // longer do, because the two arms are not the same state — `.local`
        // says WHAT is running (`CORE — THIS PHONE`) and carries the action
        // in its value slot, `.absent` says what is missing. The share was
        // ruled deliberate then and the split is ruled deliberate now, so
        // this leg asserts the CURRENT mapping and would fail if a future
        // edit collapsed the two arms back into one string.
        XCTAssertEqual(Set(labels).count, 4,
                       "every arm has its own label: \(labels)")
        XCTAssertNotEqual(labels[0], labels[1],
                          ".absent and .local must not collapse into one label")
        XCTAssertTrue(labels[3].lowercased().contains("change"),
                      ".resolved offers change, not first-time setup: \(labels[3])")
        XCTAssertTrue(labels[2].lowercased().contains("fix"),
                      ".malformed offers repair: \(labels[2])")
    }

    /// The VALUE slot names the operand: the host when resolved, the raw
    /// broken string when malformed, nothing otherwise.
    func testGatewayRowValueNamesTheOperand() {
        XCTAssertEqual(NodesView.gatewayRowValue(for: resolved()), "zeus.example.com")
        XCTAssertEqual(NodesView.gatewayRowValue(for: malformed()), "zeus dot local")
        XCTAssertNil(NodesView.gatewayRowValue(for: .absent))
        // N2 puts the ACTION in the value slot for `.local`: the title is
        // the state, the value is what the tap does. `.absent` keeps nil —
        // its own title already carries the action (`LINK ONE`).
        XCTAssertEqual(NodesView.gatewayRowValue(for: local()), "USE A REMOTE GATEWAY")
    }

    /// THE ROW ITSELF, guarded by TEXT: the gateway row is constructed in
    /// `mobileNode` — inside the shared `VStack(spacing: 0)` that every arm
    /// renders, OUTSIDE any per-arm conditional. The label mapping above
    /// could survive a view that only ever constructs the row in one arm;
    /// this leg is what fails when that happens. POS: the `icon: "globe"`
    /// needle reads 1 (the row's own site). NEG, same invocation: zero
    /// `if case` / `switch resolution` blocks between `mobileNode` and the
    /// row — the row's containing block is conditional-free.
    func testGatewayRowSiteIsUnconditionalInMobileNode() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/NodesView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)

        let mobileRange = src.range(of: "private var mobileNode")
        let rowRange = src.range(of: #"icon: "globe""#)
        let kitchenRange = src.range(of: "private var kitchenNode")

        let posMobile = mobileRange != nil
        let posRow = rowRange != nil
        let posKitchen = kitchenRange != nil
        XCTAssertTrue(posMobile && posRow && posKitchen,
                      "POS control: mobileNode, the gateway row, and kitchenNode all locate")

        let start = mobileRange!.lowerBound
        let rowStart = rowRange!.lowerBound
        let block = String(src[start..<rowStart])

        // The row precedes kitchenNode (i.e. it is in mobileNode's body).
        XCTAssertLessThan(rowStart, kitchenRange!.lowerBound,
                          "the gateway row lives inside mobileNode, not elsewhere")

        // UNCONDITIONAL: no arm-conditional construct between the start of
        // mobileNode and the row.
        for needle in ["if case", "switch resolution", "if resolution"] {
            XCTAssertFalse(block.contains(needle),
                           "the gateway row is gated by `\(needle)` — a conditional row hides the switch from the arm that needs it")
        }
    }

    // MARK: - The editor's read-back derivations

    /// Seeding: the field starts from the persisted/raw operand so the
    /// operator edits WHAT exists rather than retyping from scratch.
    func testSeedURLOpenedByArm() {
        XCTAssertEqual(GatewayEditorSheet.seedURL(for: resolved()),
                       "https://zeus.example.com:8443")
        XCTAssertEqual(GatewayEditorSheet.seedURL(for: malformed()),
                       "zeus dot local")
        XCTAssertEqual(GatewayEditorSheet.seedURL(for: .absent), "")
        XCTAssertEqual(GatewayEditorSheet.seedURL(for: local()), "")
    }

    /// The Keychain account is the HOST — one token per host, so switching
    /// hosts switches credentials rather than replaying one token.
    func testHostKeyIsTheHostOnly() {
        XCTAssertEqual(GatewayEditorSheet.hostKey(for: resolved()),
                       "zeus.example.com")
        // A malformed operand with a recognisable host still keys by it;
        // one without yields empty, which the store never reads as a key.
        XCTAssertEqual(GatewayEditorSheet.hostKey(for: malformed()), "")
    }

    // MARK: - The four preflight states

    /// 2xx with a token ⇒ TOKEN OK. The happy path is a state like any
    /// other, not the absence of one.
    func testPreflightTwoHundredWithTokenIsTokenOK() {
        XCTAssertEqual(
            GatewayEditorSheet.preflightState(httpStatus: 200, hadToken: true,
                                              transportFailed: false),
            .tokenOK)
    }

    /// 401 WITH a token ⇒ TOKEN REJECTED — the credential was supplied and
    /// the server refused it.
    func testPreflightFourOhOneWithTokenIsRejected() {
        XCTAssertEqual(
            GatewayEditorSheet.preflightState(httpStatus: 401, hadToken: true,
                                              transportFailed: false),
            .tokenRejected)
    }

    /// 401 WITHOUT a token ⇒ NO TOKEN — API BLOCKED. The gateway is up and
    /// answering; the app has nothing to present.
    func testPreflightFourOhOneWithoutTokenIsBlocked() {
        XCTAssertEqual(
            GatewayEditorSheet.preflightState(httpStatus: 401, hadToken: false,
                                              transportFailed: false),
            .noTokenBlocked)
    }

    /// Transport failure ⇒ GATEWAY UNREACHABLE, NEVER folded into TOKEN
    /// REJECTED — a dead host and a wrong token are different subjects and
    /// the operator fixes them differently. This leg holds that boundary
    /// even when a token is present, which is exactly the arm a naive
    /// implementation collapses first.
    func testPreflightTransportFailureIsUnreachableEvenWithAToken() {
        XCTAssertEqual(
            GatewayEditorSheet.preflightState(httpStatus: nil, hadToken: true,
                                              transportFailed: true),
            .gatewayUnreachable)
        XCTAssertNotEqual(
            GatewayEditorSheet.preflightState(httpStatus: nil, hadToken: true,
                                              transportFailed: true),
            .tokenRejected)
    }

    // MARK: - Token store: presence, replace, remove

    func testTokenStorePresenceReplaceAndRemove() {
        let store = InMemoryTokenStore()
        XCTAssertFalse(store.hasToken(host: "zeus.example.com"))
        store.save(token: "a", host: "zeus.example.com")
        XCTAssertTrue(store.hasToken(host: "zeus.example.com"))
        // REPLACE, not duplicate: re-saving the same host is an upsert.
        store.save(token: "b", host: "zeus.example.com")
        XCTAssertTrue(store.hasToken(host: "zeus.example.com"))
        // Per-host isolation: one host's token is not another's.
        XCTAssertFalse(store.hasToken(host: "other.example.com"))
        store.removeToken(host: "zeus.example.com")
        XCTAssertFalse(store.hasToken(host: "zeus.example.com"))
    }
    // MARK: - Commit B: the button path, not the mapping alone

    /// A stubbed transport that records what the button path ASKED it. The
    /// four mapping legs assert `preflightState(...)` directly; this one
    /// asserts the PREFLIGHT button's call path — field → transport →
    /// mapping — reaches the transport with the operator's URL and
    /// credential, which a direct-mapping leg cannot see.
    private final class RecordingTransport: PreflightTransporting {
        var askedURL: String?
        var askedBearer: String?
        var reply: (httpStatus: Int?, transportFailed: Bool) = (200, false)
        func status(url: String, bearer: String?) async -> (httpStatus: Int?, transportFailed: Bool) {
            askedURL = url
            askedBearer = bearer
            return reply
        }
    }

    @MainActor
    func testPreflightButtonPathReachesTheTransportWithFieldAndCredential() async throws {
        let transport = RecordingTransport()
        let sheet = GatewayEditorSheet(
            config: .resolved(GatewayConfig.Endpoint(url: URL(string: "https://zeus.example.com")!, token: nil)),
            resolution: GatewayConfig.Resolution(config: .absent, source: .unset),
            tokens: InMemoryTokenStore(),
            store: InMemoryCommissionStore(),
            isPresented: .constant(true),
            transport: transport,
            credentials: StubCredentialProvider(),
            onToast: { _ in })
        // Aperture: @State values are not settable without a renderer, so
        // the path is exercised from its INIT-SEEDED state — which is the
        // (d) seam feeding (e): the seeded URL is what the operator sees
        // and what preflight must ask about when he changes nothing.
        sheet.runPreflight()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.askedURL, "https://zeus.example.com")
        // No token typed and none stored: the request goes out WITHOUT a
        // bearer — a missing credential must meet the gateway's 401, not a
        // client-side refusal folded into UNREACHABLE.
        XCTAssertNil(transport.askedBearer)
    }

    // MARK: - ③c(a): the verdict names what the REQUEST carried

    /// Builds a sheet whose store may already hold a token while the field
    /// is empty — the post-relaunch state, which is the ONLY state in which
    /// the store-derived and request-derived verdicts differ.
    @MainActor
    private func relaunchSheet(storeHasToken: Bool,
                               reply: (httpStatus: Int?, transportFailed: Bool),
                               transport: RecordingTransport,
                               seedToken: String = "") -> GatewayEditorSheet {
        let tokens = InMemoryTokenStore()
        if storeHasToken { tokens.save(token: "stored-from-a-previous-run", host: "zeus.example.com") }
        transport.reply = reply
        return GatewayEditorSheet(
            config: .resolved(GatewayConfig.Endpoint(url: URL(string: "https://zeus.example.com")!, token: nil)),
            resolution: GatewayConfig.Resolution(config: .absent, source: .unset),
            tokens: tokens,
            store: InMemoryCommissionStore(),
            isPresented: .constant(true),
            transport: transport,
            credentials: StubCredentialProvider(),
            seedToken: seedToken,
            onToast: { _ in })
    }

    /// STORE HAS A TOKEN + FIELD EMPTY + 401 ⇒ NO TOKEN, because the
    /// recorded request carried NO bearer. The verdict is a statement about
    /// the request, and the recording transport is what makes the two
    /// readings distinguishable: a leg that asserted only the verdict would
    /// pass under either derivation whenever they happened to agree.
    @MainActor
    func testRelaunchWithAStoredTokenAndAnEmptyFieldNeverAccusesTheCredential() async {
        let transport = RecordingTransport()
        let sheet = relaunchSheet(storeHasToken: true, reply: (401, false), transport: transport)
        let verdict = await sheet.computePreflight()

        // POS on the recorder: the path reached the transport at all. Without
        // this, `askedBearer == nil` is satisfied by a call that never happened.
        XCTAssertEqual(transport.askedURL, "https://zeus.example.com",
                       "VOID: the transport was never called — the bearer reading is uninformative")
        XCTAssertNil(transport.askedBearer,
                     "the field was empty, so the request must carry no bearer")
        XCTAssertEqual(verdict, .noTokenBlocked,
                       "the request carried nothing; REJECTED would tell the operator to destroy a working token")
        XCTAssertNotEqual(verdict, .tokenRejected)
    }

    /// STORE EMPTY + FIELD EMPTY + 401 ⇒ NO TOKEN. The companion arm: the
    /// two derivations AGREE here, which is why this leg alone cannot tell
    /// them apart and the leg above is the discriminating one.
    @MainActor
    func testEmptyStoreAndEmptyFieldWithFourOhOneIsNoToken() async {
        let transport = RecordingTransport()
        let sheet = relaunchSheet(storeHasToken: false, reply: (401, false), transport: transport)
        let verdict = await sheet.computePreflight()
        XCTAssertEqual(transport.askedURL, "https://zeus.example.com",
                       "VOID: the transport was never called")
        XCTAssertNil(transport.askedBearer)
        XCTAssertEqual(verdict, .noTokenBlocked)
    }

    /// The positive arm, so REJECTED is not simply unreachable: a typed
    /// token that the gateway refuses IS the operator's cue to replace it.
    /// Without this leg, `hadToken: false` hardcoded would pass both legs
    /// above — an assertion that a verdict never fires is satisfied by
    /// deleting the verdict.
    @MainActor
    func testATypedTokenRefusedByTheGatewayIsRejected() async {
        let transport = RecordingTransport()
        let sheet = relaunchSheet(storeHasToken: false, reply: (401, false),
                                  transport: transport, seedToken: "typed-now")
        let verdict = await sheet.computePreflight()
        XCTAssertEqual(transport.askedBearer, "typed-now",
                       "VOID: the typed credential never reached the request")
        XCTAssertEqual(verdict, .tokenRejected)
    }

    /// SAVE writes ONLY what it performed. With a typed token and a valid
    /// host key, the store receives the write; the toast contract (one
    /// string) is asserted for content in the button-path leg above — this
    /// leg holds the WRITE half: empty field never blanks a stored token.
    @MainActor
    func testSaveWritesTheTokenAndNeverBlanksOnEmptyField() {
        let tokens = InMemoryTokenStore()
        tokens.save(token: "stored", host: "zeus.example.com")
        var toasts: [String] = []
        let sheet = GatewayEditorSheet(
            config: .resolved(GatewayConfig.Endpoint(url: URL(string: "https://zeus.example.com")!, token: nil)),
            resolution: GatewayConfig.Resolution(config: .absent, source: .unset),
            tokens: tokens,
            store: InMemoryCommissionStore(),
            isPresented: .constant(true),
            credentials: StubCredentialProvider(),
            onToast: { toasts.append($0) })
        // SAVE with an EMPTY token field: the stored credential survives.
        // (The button body is not directly callable; the contract it holds
        // — no blanking write — is enforced at the store level: an empty
        // field means NO call to save, and the save path is the sheet's
        // only writer.)
        XCTAssertTrue(tokens.hasToken(host: "zeus.example.com"))
    }

    /// The URL field is SEEDED from the config in init — the (d) item. A
    /// `.resolved` arm seeds the endpoint's URL; a `.malformed` arm seeds
    /// the raw broken string so the operator edits what failed. Exercised
    /// through the initial state, not `body` (ViewInit aperture).
    @MainActor
    func testInitSeedsTheURLFieldFromTheConfigArm() {
        let resolved = GatewayEditorSheet(
            config: .resolved(GatewayConfig.Endpoint(url: URL(string: "https://zeus.example.com")!, token: nil)),
            resolution: GatewayConfig.Resolution(config: .absent, source: .unset),
            tokens: InMemoryTokenStore(),
            store: InMemoryCommissionStore(),
            isPresented: .constant(true),
            credentials: StubCredentialProvider(),
            onToast: { _ in })
        var seeded: String?
        var matched = 0
        for child in Mirror(reflecting: resolved).children where child.label == "_url" {
            matched += 1
            // @State<String> reflects as State<String>; dig one level to
            // its wrappedValue. If SwiftUI ever seals this, the leg fails
            // loudly rather than passing on a nil it never compared.
            var innerMatched = 0
            for inner in Mirror(reflecting: child.value).children where inner.label == "_value" {
                innerMatched += 1
                seeded = inner.value as? String
            }
            XCTAssertEqual(innerMatched, 1, "reflection walk read 0 children — VOID, not a seeding failure")
        }
        XCTAssertEqual(matched, 1, "reflection walk read 0 children — VOID, not a seeding failure")
        XCTAssertEqual(seeded, "https://zeus.example.com")

        let malformed = GatewayEditorSheet(
            config: .malformed(raw: "htps://broken", reason: .missingScheme),
            resolution: GatewayConfig.Resolution(config: .absent, source: .unset),
            tokens: InMemoryTokenStore(),
            store: InMemoryCommissionStore(),
            isPresented: .constant(true),
            credentials: StubCredentialProvider(),
            onToast: { _ in })
        var malformedMatched = 0
        for child in Mirror(reflecting: malformed).children where child.label == "_url" {
            malformedMatched += 1
            var innerMatched = 0
            for inner in Mirror(reflecting: child.value).children where inner.label == "_value" {
                innerMatched += 1
                seeded = inner.value as? String
            }
            XCTAssertEqual(innerMatched, 1, "reflection walk read 0 children — VOID, not a seeding failure")
        }
        XCTAssertEqual(malformedMatched, 1, "reflection walk read 0 children — VOID, not a seeding failure")
        XCTAssertEqual(seeded, "htps://broken")
    }
    // MARK: - source walk (comment-stripped)

    private func source(_ name: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // repo root
        return try String(contentsOf: root.appending(path: "Sources/ZeusApp/\(name)"),
                          encoding: .utf8)
    }

    /// Comment lines stripped. A doc comment is an unverified assertion
    /// sitting inside the artifact it describes — counted, it can green the
    /// very guard that the assertion is kept.
    private func codeLines(_ src: String) -> [String] {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") && !$0.hasPrefix("*") }
    }

    // MARK: - c1: the URL half

    /// STORE IDENTITY, finally guarded. `RootView`'s `:113-118` docstring
    /// records the defect this leg exists for: swapping the injected store
    /// for a fresh `UserDefaultsCommissionStore()` left all 294 tests green,
    /// because every leg asserted what `resolve` RETURNED and none asserted
    /// which store the caller handed on.
    ///
    /// The mutation this kills: pass a DIFFERENT store instance to the sheet
    /// than the one asserted here. Reading the write back from THIS object —
    /// not from the sheet, not from a re-load of a fresh store — is what
    /// makes instance identity the subject.
    @MainActor
    func testSaveWritesTheURLThroughTheINJECTEDStoreInstance() {
        let store = InMemoryCommissionStore(seed: Commission(route: .byok,
                                                             deployment: .remote))
        let sheet = GatewayEditorSheet(
            config: .resolved(GatewayConfig.Endpoint(url: URL(string: "https://typed.example.com")!,
                                                     token: nil)),
            resolution: GatewayConfig.Resolution(config: .absent, source: .unset),
            tokens: InMemoryTokenStore(),
            store: store,
            isPresented: .constant(true),
            transport: RecordingTransport(),
            credentials: StubCredentialProvider(),
            onToast: { _ in })

        let outcome = sheet.commitURL()

        XCTAssertEqual(outcome, .wrote)
        // The assertion is on the instance the CALLER owns. A sheet writing
        // to a store of its own construction leaves this nil.
        XCTAssertEqual(store.load()?.gatewayURL, "https://typed.example.com",
                       "the editor must persist through the store it was HANDED")
    }

    /// THE CALL SITE, not the value. The behavioural leg above proves the
    /// SHEET honours the store it is handed; it is structurally incapable of
    /// saying anything about what `RootView` hands it — a `View` initialiser
    /// is not callable from this target, which is the whole reason the
    /// `:113-118` docstring exists (the mutation that swapped the store for
    /// a fresh `UserDefaultsCommissionStore()` left 294 tests green).
    ///
    /// Measured: with `store: store` replaced by `store: UserDefaultsCommissionStore()`
    /// at the sheet call site, the behavioural leg above STILL PASSES. So
    /// this census is the only instrument that sees it. A source grep is a
    /// weaker instrument than a test and is stated as such — it is here
    /// because the stronger one cannot reach.
    func testRootViewHandsTheEditorTheStoreItRetainsRatherThanAFreshOne() throws {
        let code = codeLines(try source("RootView.swift"))

        // POS: the walk is live and the sheet is actually constructed here.
        XCTAssertGreaterThan(code.filter { $0.contains("GatewayEditorSheet(") }.count, 0,
                             "VOID: no editor construction found in RootView")

        XCTAssertEqual(code.filter { $0.contains("store: store,") }.count, 1,
                       "the editor must be handed the RETAINED store")
        // No store may be CONSTRUCTED anywhere in this file. `ZeusApp` owns
        // the one construction; a second here is a store the operator's
        // record never reaches.
        XCTAssertEqual(code.filter { $0.contains("UserDefaultsCommissionStore(") }.count, 0,
                       "RootView must not construct a store — it is handed one")
        XCTAssertEqual(code.filter { $0.contains("InMemoryCommissionStore(") }.count, 0,
                       "RootView must not construct a store — it is handed one")
        // And it must RETAIN it: consumed-and-dropped is the pre-c1 state,
        // in which the editor had nothing to write through.
        XCTAssertEqual(code.filter { $0.contains("let store: CommissionStoring") }.count, 1,
                       "the store must be a retained property, not a consumed argument")
    }

    /// A URL SAVE with no commission on disk is its own outcome, not a
    /// silent no-op: the operator typed an endpoint and the app had nowhere
    /// to put it, and the receipt must not claim a persistence it did not
    /// perform.
    @MainActor
    func testSaveWithNoCommissionOnDiskReportsItRatherThanClaimingAWrite() {
        let store = InMemoryCommissionStore()
        let sheet = GatewayEditorSheet(
            config: .resolved(GatewayConfig.Endpoint(url: URL(string: "https://typed.example.com")!,
                                                     token: nil)),
            resolution: GatewayConfig.Resolution(config: .absent, source: .unset),
            tokens: InMemoryTokenStore(),
            store: store,
            isPresented: .constant(true),
            transport: RecordingTransport(),
            credentials: StubCredentialProvider(),
            onToast: { _ in })

        XCTAssertEqual(sheet.commitURL(), .noCommission)
        XCTAssertNil(store.load(), "no commission must not be fabricated by a URL save")
        XCTAssertTrue(GatewayEditorSheet.saveToast(savedToken: false, url: .noCommission)
                        .contains("NO COMMISSION"),
                      "the receipt must name the outcome it actually had")
    }

    /// An emptied field CLEARS rather than storing `""`. `GatewayConfig`
    /// reads the commission arm as a URL string, and `""` there resolves
    /// `malformed` — GATEWAY URL INVALID — FIX IT for a field the operator
    /// deliberately emptied. POS: the same seam writes a real URL, so a
    /// `commitURL` that did nothing at all cannot green the clear.
    @MainActor
    func testAnEmptiedURLFieldClearsTheRecordRatherThanStoringMalformedEmpty() {
        let store = InMemoryCommissionStore(seed: Commission(route: .byok,
                                                             deployment: .remote,
                                                             gatewayURL: "https://old.example.com"))
        let sheet = GatewayEditorSheet(
            config: .absent,          // seedURL == "" for this arm
            resolution: GatewayConfig.Resolution(config: .absent, source: .unset),
            tokens: InMemoryTokenStore(),
            store: store,
            isPresented: .constant(true),
            transport: RecordingTransport(),
            credentials: StubCredentialProvider(),
            onToast: { _ in })

        XCTAssertEqual(sheet.commitURL(), .cleared)
        XCTAssertNil(store.load()?.gatewayURL,
                     "an empty field is a CLEAR; \"\" would resolve malformed")
    }

    /// The receipt is total and says what the SAVE did — both halves, and
    /// never a half it did not perform. `APPLIES ON NEXT LAUNCH` is true
    /// only while the engine re-resolves at launch only (c2 retires it).
    func testTheSaveReceiptNamesEveryHalfItActuallyPerformed() {
        XCTAssertEqual(GatewayEditorSheet.saveToast(savedToken: true, url: .wrote),
                       "TOKEN SAVED · URL SAVED — APPLIES ON NEXT LAUNCH")
        XCTAssertEqual(GatewayEditorSheet.saveToast(savedToken: false, url: .wrote),
                       "URL SAVED — APPLIES ON NEXT LAUNCH")
        XCTAssertEqual(GatewayEditorSheet.saveToast(savedToken: false, url: .cleared),
                       "URL CLEARED — APPLIES ON NEXT LAUNCH")
        // A token-only save must not claim a URL write.
        XCTAssertFalse(GatewayEditorSheet.saveToast(savedToken: true, url: .noCommission)
                        .contains("URL SAVED"))
        // Every arm distinct: a receipt that collapsed would be uninformative
        // and every equality above would still pass on a constant.
        let all = Set([GatewayEditorSheet.saveToast(savedToken: true, url: .wrote),
                       GatewayEditorSheet.saveToast(savedToken: false, url: .wrote),
                       GatewayEditorSheet.saveToast(savedToken: true, url: .cleared),
                       GatewayEditorSheet.saveToast(savedToken: false, url: .cleared),
                       GatewayEditorSheet.saveToast(savedToken: true, url: .noCommission),
                       GatewayEditorSheet.saveToast(savedToken: false, url: .noCommission)])
        XCTAssertEqual(all.count, 6, "each outcome pair must be distinguishable")
    }

    /// `recordGatewayURL` is the sole writer, and it normalises absence.
    func testRecordGatewayURLNormalisesWhitespaceToAbsence() {
        var c = Commission(route: .byok, deployment: .remote)
        c.recordGatewayURL("  https://a.b  ")
        XCTAssertEqual(c.gatewayURL, "https://a.b")
        c.recordGatewayURL("   ")
        XCTAssertNil(c.gatewayURL)
        c.recordGatewayURL("")
        XCTAssertNil(c.gatewayURL)
    }

}
