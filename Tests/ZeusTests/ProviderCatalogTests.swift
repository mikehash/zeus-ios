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
        c.recordRoutesChoice(providerID: "xiaomimimo", model: "m")

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
        c.recordRoutesChoice(providerID: "anthropic", model: "claude-sonnet-4-6")

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
        c.recordRoutesChoice(providerID: "ollama", model: "llama3.2:latest")

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
        var keyed = Commission(); keyed.recordRoutesChoice(providerID: "anthropic", model: "m")
        var keyless = Commission(); keyless.recordRoutesChoice(providerID: "ollama", model: "m")

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
        XCTAssertFalse(V.routesCTAEnabled(providerPick: nil, modelText: ""),
                       "neither half given")
        XCTAssertFalse(V.routesCTAEnabled(providerPick: "ollama", modelText: ""),
                       "a provider with no model must not write a half record")
        XCTAssertFalse(V.routesCTAEnabled(providerPick: "ollama", modelText: "   "),
                       "whitespace is not a model")
        XCTAssertFalse(V.routesCTAEnabled(providerPick: nil, modelText: "llama3.2"),
                       "a model with no provider must not write a half record")
        XCTAssertTrue(V.routesCTAEnabled(providerPick: "ollama", modelText: "llama3.2"),
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
