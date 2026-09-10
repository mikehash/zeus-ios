import XCTest
@testable import Zeus

/// A catalog the test owns, so a leg about labels is not a leg about whichever
/// providers the linked core happens to carry today.
struct StubCatalog: ProviderCataloging {
    var rows_: [ProviderRow]
    var shapes: [String: CredentialKind] = [:]
    init(rows: [ProviderRow], shapes: [String: CredentialKind] = [:]) {
        self.rows_ = rows
        self.shapes = shapes
    }
    func rows() -> [ProviderRow] { rows_ }
    func shape(for id: String) -> CredentialKind {
        shapes[id] ?? rows_.first { $0.id == id }?.shape
            ?? .unsupported(reason: "the core does not know this provider")
    }
}

/// A core double local to this file. `ArmingCore` in `ProviderArmingTests` is
/// `private` to that class by design, and reaching for it would couple two
/// suites through a fixture neither owns.
private final class CatalogCore: ZeusCoreProtocol {
    let refuse: Bool
    private(set) var setCalls: [(id: String, model: String, key: String, baseUrl: String?)] = []
    private var armed = false
    init(refuse: Bool = false) { self.refuse = refuse }

    func hasProvider() -> Bool { armed }
    func setProvider(id: String, model: String, key: String, baseUrl: String?) throws {
        setCalls.append((id, model, key, baseUrl))
        if refuse { throw NSError(domain: "test", code: 1) }
        armed = true
    }
    func listModels(id: String, key: String, baseUrl: String?) throws -> [String] { [] }
    func indexSize() -> UInt32 { 0 }
    func send(sessionId: String, text: String, sink: TokenSink) throws {}
    func sessions() throws -> [SessionInfo] { [] }
    func messages(sessionId: String) throws -> [TurnMessage] { [] }
    func remember(fact: String) throws {}
    func search(query: String) -> [SearchHit] { [] }
}

final class ProviderCatalogTests: XCTestCase {

    private var saved: ProviderCataloging!
    override func setUp() { saved = ProviderCatalog.current }
    override func tearDown() { ProviderCatalog.current = saved }

    // MARK: The label surfaces

    /// THE FOUR PROVIDER-ID SURFACES RENDER THE CORE'S LABEL.
    ///
    /// One footer (`Commission.summary`) and one function (`CoreArming.arm`,
    /// three arms). The needle is a label whose upper-cased id is a DIFFERENT
    /// string, so `id.uppercased()` cannot pass this leg by coincidence —
    /// `xiaomimimo` → `Xiaomi MiMo` is the case the catalog exists for.
    func testAllFourProviderIDSurfacesRenderTheLabelNotTheUppercasedID() {
        ProviderCatalog.current = StubCatalog(rows: [
            ProviderRow(id: "xiaomimimo", label: "Xiaomi MiMo", shape: .key)
        ])

        var c = Commission()
        c.recordRoutesChoice(providerID: "xiaomimimo", model: "m", baseURL: nil)

        // 1. the summary footer
        XCTAssertTrue(c.summary.contains("Xiaomi MiMo"), c.summary)
        XCTAssertFalse(c.summary.contains("XIAOMIMIMO"), c.summary)

        // 2. NO MODEL arm
        var noModel = c
        noModel.model = nil
        let m = CoreArming.arm(commission: noModel, core: CatalogCore(), providerKey: "k", baseURL: nil)
        XCTAssertEqual(m, "NO MODEL — Xiaomi MiMo LISTED NONE", String(describing: m))

        // 3. NO KEY arm
        let k = CoreArming.arm(commission: c, core: CatalogCore(), providerKey: nil, baseURL: nil)
        XCTAssertEqual(k, "NO KEY FOR Xiaomi MiMo — ENTER ONE IN ROUTES", String(describing: k))

        // 4. REFUSED arm
        let r = CoreArming.arm(commission: c, core: CatalogCore(refuse: true), providerKey: "k", baseURL: nil)
        XCTAssertTrue(r?.hasPrefix("Xiaomi MiMo REFUSED") == true, String(describing: r))
        XCTAssertFalse(r?.contains("XIAOMIMIMO") == true, String(describing: r))
    }

    /// AN ID THE CATALOG DOES NOT HOLD RENDERS VERBATIM — not upper-cased,
    /// not title-cased. An unknown id is a fact about the record and dressing
    /// it up as a display name is the fabrication class this cut retires.
    func testAnUnknownIDRendersVerbatim() {
        ProviderCatalog.current = StubCatalog(rows: [])
        XCTAssertEqual(ProviderCatalog.label(for: "somethingnew"), "somethingnew")
    }

    /// POS CONTROL for the leg above: the same lookup, WITH the row present,
    /// so the verbatim result is a property of the absent row and not of a
    /// lookup that ignores its catalog.
    func testTheSameLookupFindsARowThatIsPresent() {
        ProviderCatalog.current = StubCatalog(rows: [
            ProviderRow(id: "somethingnew", label: "Something New", shape: .key)
        ])
        XCTAssertEqual(ProviderCatalog.label(for: "somethingnew"), "Something New")
    }

    // MARK: The ruled arming legs

    /// RULED LEG: a `shape == .key` row with a TYPED MODEL and NO KEY arms to
    /// `NO KEY FOR <label>`, not `NO MODEL`.
    ///
    /// This is the discriminator between "the model field works" and "the
    /// model field is decorative": before the typed field, a keyed provider
    /// could never get past `NO MODEL` — `list_models` is Ollama-only, so
    /// `firstModel` returned nil for all 21 of them and the key state was
    /// unreachable. Reaching NO KEY is the proof the model half is collected.
    func testAKeyedProviderWithATypedModelAndNoKeyReachesTheKeyState() {
        ProviderCatalog.current = StubCatalog(rows: [
            ProviderRow(id: "anthropic", label: "Anthropic", shape: .key)
        ])
        var c = Commission()
        c.recordRoutesChoice(providerID: "anthropic", model: "claude-sonnet-4-6", baseURL: nil)

        let reason = CoreArming.arm(commission: c, core: CatalogCore(), providerKey: nil, baseURL: nil)
        XCTAssertEqual(reason, "NO KEY FOR Anthropic — ENTER ONE IN ROUTES", String(describing: reason))
        XCTAssertFalse(reason?.contains("NO MODEL") == true,
                       "the typed model must be what carries it past the model gate")
    }

    /// RULED POS: an Ollama row with a URL and a picked model ARMS.
    ///
    /// Ollama's shape is `Url`, which is not a secret, so it is the arm that
    /// can actually arm before the key store lands — the reason ④a ships
    /// ahead of ④b.
    func testAnOllamaRowWithAModelArms() {
        ProviderCatalog.current = StubCatalog(rows: [
            ProviderRow(id: "ollama", label: "Ollama", shape: .url)
        ])
        var c = Commission()
        c.recordRoutesChoice(providerID: "ollama", model: "llama3.2:latest", baseURL: nil)

        let core = CatalogCore()
        let reason = CoreArming.arm(commission: c, core: core,
                                    providerKey: nil, baseURL: "http://localhost:11434")
        XCTAssertNil(reason, String(describing: reason))
        XCTAssertEqual(core.setCalls.first?.model, "llama3.2:latest")
        XCTAssertEqual(core.setCalls.first?.id, "ollama")
    }

    /// VACUITY: the two legs above must be able to DISAGREE. A `CoreArming`
    /// that returned the same thing for both would satisfy each assertion
    /// shape read on its own.
    func testTheKeyedAndKeylessArmsAreNotTheSameOutcome() {
        ProviderCatalog.current = StubCatalog(rows: [
            ProviderRow(id: "anthropic", label: "Anthropic", shape: .key),
            ProviderRow(id: "ollama", label: "Ollama", shape: .url)
        ])
        var keyed = Commission(); keyed.recordRoutesChoice(providerID: "anthropic", model: "m", baseURL: nil)
        var keyless = Commission(); keyless.recordRoutesChoice(providerID: "ollama", model: "m", baseURL: nil)

        let a = CoreArming.arm(commission: keyed, core: CatalogCore(), providerKey: nil, baseURL: nil)
        let b = CoreArming.arm(commission: keyless, core: CatalogCore(), providerKey: nil, baseURL: nil)
        XCTAssertNotEqual(a, b, "keyed-without-key and keyless must not collapse to one outcome")
    }

    // MARK: The CTA gate

    /// THE CTA REQUIRES BOTH HALVES, AND THIS LEG EXISTS BECAUSE THE MODIFIER
    /// FORM HAD NO GUARD: `.disabled(...)` → `.disabled(false)` inside the
    /// view body left all 424 tests green (measured), which is the
    /// no-importable-surface class one file over from `main.rs`.
    func testTheRoutesCTARequiresBothAProviderAndAModel() {
        typealias V = CommissioningView
        XCTAssertFalse(V.routesCTAEnabled(providerPick: nil, modelText: "", shape: nil, baseURLText: ""),
                       "neither half given")
        XCTAssertFalse(V.routesCTAEnabled(providerPick: "ollama", modelText: "", shape: .key, baseURLText: ""),
                       "a provider with no model must not write a half record")
        XCTAssertFalse(V.routesCTAEnabled(providerPick: "ollama", modelText: "   ", shape: .key, baseURLText: ""),
                       "whitespace is not a model")
        XCTAssertFalse(V.routesCTAEnabled(providerPick: nil, modelText: "llama3.2", shape: .key, baseURLText: ""),
                       "a model with no provider must not write a half record")
        XCTAssertTrue(V.routesCTAEnabled(providerPick: "ollama", modelText: "llama3.2", shape: .key, baseURLText: ""),
                      "POS: both halves given — a gate that refused everything would pass every leg above")
    }

    // MARK: The shape seam

    /// AN ID THE CORE REJECTS RENDERS AS AN ERROR, NOT AS "NOTHING TO COLLECT".
    ///
    /// `credential_shape` THROWS on an unknown id (`zeus_core_bridge:1665`);
    /// it never answers `.none` for one. Nothing reachable today produces an
    /// unknown id — every row comes from the catalog — which is exactly why
    /// the arm is written now rather than after a core adds a variant.
    func testAnUnknownIDIsUnsupportedNotNone() {
        ProviderCatalog.current = StubCatalog(rows: [])
        guard case .unsupported = ProviderCatalog.current.shape(for: "nope") else {
            return XCTFail("an unknown id must be an error state, not `.none`")
        }
    }

    /// POS CONTROL: the same seam answers a known id with its real shape, so
    /// the unsupported verdict above is a property of the unknown id and not
    /// of a seam that answers unsupported for everything.
    func testAKnownIDAnswersItsRealShape() {
        ProviderCatalog.current = StubCatalog(rows: [
            ProviderRow(id: "ollama", label: "Ollama", shape: .url)
        ])
        XCTAssertEqual(ProviderCatalog.current.shape(for: "ollama"), .url)
    }
}

// MARK: - (i) The `url` shape: GATE ONE — the field exists and the CTA holds

/// The two gates are SEPARATE CLAIMS and neither implies the other.
///
/// Before this cut the picker rendered a field only `if case .key`, and the arm
/// read its `baseURL` argument from `LaunchArgs.seededProvider` — which is
/// `#else return nil` in release. So a URL collected by the form would have had
/// nowhere to go, and a URL on the record would have had no reader. A leg on
/// either half alone passes while the feature does nothing.
final class ProviderBaseURLGateTests: XCTestCase {

    private var saved: ProviderCataloging!

    override func setUp() {
        super.setUp()
        saved = ProviderCatalog.current
        ProviderCatalog.current = StubCatalog(rows: [
            ProviderRow(id: "ollama", label: "Ollama", shape: .url),
            ProviderRow(id: "anthropic", label: "Anthropic", shape: .key),
        ])
    }

    override func tearDown() {
        ProviderCatalog.current = saved
        super.tearDown()
    }

    /// GATE ONE. A `.url` provider with a model but no endpoint must not pass
    /// the CTA — it is the one shape that satisfies every other gate and is
    /// still unarmable.
    func testTheCTARefusesAURLProviderWithNoEndpoint() {
        typealias V = CommissioningView
        XCTAssertFalse(V.routesCTAEnabled(providerPick: "ollama",
                                          modelText: "llama3.2",
                                          shape: .url,
                                          baseURLText: ""),
                       "a url-shape provider with no endpoint writes a record that cannot arm")
        XCTAssertFalse(V.routesCTAEnabled(providerPick: "ollama",
                                          modelText: "llama3.2",
                                          shape: .url,
                                          baseURLText: "   "),
                       "whitespace is not an endpoint")
        XCTAssertTrue(V.routesCTAEnabled(providerPick: "ollama",
                                         modelText: "llama3.2",
                                         shape: .url,
                                         baseURLText: "http://10.0.0.2:11434"),
                      "POS: endpoint given — a gate that refused everything would pass the two above")
        // DISCRIMINATOR: the same empty endpoint must NOT block a `.key`
        // provider. Without this the leg above is a statement about
        // `baseURLText.isEmpty`, not about the shape.
        XCTAssertTrue(V.routesCTAEnabled(providerPick: "anthropic",
                                         modelText: "claude-sonnet-4-6",
                                         shape: .key,
                                         baseURLText: ""),
                      "a keyed provider has no endpoint to give and must not be gated on one")
    }

    /// The field is rendered for `.url` and only for `.url`.
    ///
    /// Source census, because the branch lives in a view `body` and a `body`
    /// modifier is unreachable from this target — the same no-importable-surface
    /// limit that let `.disabled(false)` pass 424 tests.
    func testTheEndpointFieldIsRenderedForTheURLShape() throws {
        let src = try source("Commissioning.swift")
        XCTAssertTrue(src.contains("if case .url = selected.shape {"),
                      "the url arm must exist beside the key arm")
        XCTAssertTrue(src.contains("baseURLField(for: selected)"),
                      "and it must render the endpoint field")
        // POS in the same invocation: the key arm still stands, so a miss above
        // is about the url arm and not about the reader.
        XCTAssertTrue(src.contains("if case .key = selected.shape {"),
                      "POS: the key arm is untouched")
    }

    /// GATE TWO. The arm reads the RECORD, not the debug seed.
    ///
    /// MUT: revert `RootView` to `baseURL: seeded?.baseURL` and this fires —
    /// in a release build that argument is unconditionally nil.
    func testTheArmReadsTheEndpointFromTheRecordAndNotOnlyTheSeed() throws {
        let src = try source("RootView.swift")
        XCTAssertTrue(src.contains("commissionForArming?.providerBaseURL"),
                      "the record must be a source for the arm's baseURL")
        XCTAssertTrue(src.contains("providerKey: key"),
                      "POS: the sibling argument still reads the store")
    }

    /// The record round-trips the endpoint, and an empty field is ABSENCE.
    func testTheEndpointRoundTripsAndEmptyNormalisesToNil() throws {
        var c = Commission()
        c.recordRoutesChoice(providerID: "ollama", model: "llama3.2", baseURL: "  http://10.0.0.2:11434  ")
        XCTAssertEqual(c.providerBaseURL, "http://10.0.0.2:11434", "trimmed, not stored raw")

        let round = try JSONDecoder().decode(
            Commission.self, from: try JSONEncoder().encode(c))
        XCTAssertEqual(round.providerBaseURL, c.providerBaseURL, "survives a store round trip")

        var blank = Commission()
        blank.recordRoutesChoice(providerID: "ollama", model: "llama3.2", baseURL: "   ")
        XCTAssertNil(blank.providerBaseURL,
                     "empty is absence, not an endpoint the core accepts and then fails on")
    }

    /// MIGRATION: a record written before the key existed still decodes.
    func testALegacyRecordWithoutAnEndpointStillDecodes() throws {
        let legacy = #"{"route":"byok","provider":"ollama","callsign":"x","node_enrolled":false,"model":"llama3.2"}"#
        let c = try JSONDecoder().decode(Commission.self, from: Data(legacy.utf8))
        XCTAssertNil(c.providerBaseURL)
        XCTAssertEqual(c.model, "llama3.2", "POS: the sibling key still decodes")
    }

    /// THE ENDPOINT IS NOT THE GATEWAY URL. Two subjects, two fields — writing
    /// one through the other makes a LOCAL install read as a REMOTE gateway
    /// config in `GatewayConfig.resolve`.
    func testTheEndpointDoesNotTouchTheGatewayURL() {
        var c = Commission()
        c.recordRoutesChoice(providerID: "ollama", model: "m", baseURL: "http://10.0.0.2:11434")
        XCTAssertNil(c.gatewayURL, "the provider endpoint must not land in the remote arm's field")
        XCTAssertNotEqual(c.providerBaseURL, c.gatewayURL,
                          "vacuity: two nils would pass the line above while proving nothing")
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The default `http://localhost:11434` appears as a PROMPT and never as a
    /// stored value: on a phone, localhost is the phone.
    func testTheLocalhostDefaultIsAPromptAndNotAValue() throws {
        let src = try source("Commissioning.swift")
        XCTAssertTrue(src.contains(#"prompt:"#), "POS: the file uses the prompt API")
        XCTAssertFalse(src.contains(#"baseURLText: String = "http://localhost"#),
                       "the state must not be seeded with the daemon default")
        XCTAssertFalse(src.contains(#"providerBaseURL ?? "http://localhost"#),
                       "and no reader may substitute it either")
    }
}
