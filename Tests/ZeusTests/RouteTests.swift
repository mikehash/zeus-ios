import XCTest
@testable import Zeus

/// Legs for the FETCHED route catalogue behind the C12 sheet.
///
/// Every leg here was written against its own VACUOUS form first — the form
/// that would pass on a stub — and only kept if the vacuous form fails.
///
/// ⚠️ APERTURE. These legs exercise the decode, the derivation, the store's
/// state machine and the strings. They do NOT prove the app talks to a real
/// gateway: `URLSession` is not exercised here, and `HTTPRouteCatalogFetcher`
/// is constructed but never `fetch`ed against a socket. What backs the wire
/// claim is a live `curl` table in the commit body, run on this box against
/// `~/Zeus@8746e17e4` — a measurement made once, by hand, not a leg that
/// re-runs. Said here rather than left implied.
final class RouteTests: XCTestCase {

    // MARK: - fixtures

    /// The gateway's own payload shape, trimmed to the fields the app decodes.
    /// This fixture lives in the TEST TARGET and only in the test target —
    /// production has no vendored provider list at all, which is the point of
    /// the commit. If this array ever appears under `Sources/`, the defect is
    /// back.
    private static let payload = """
    {"providers":[
      {"id":"anthropic","name":"Anthropic","tagline":"Claude models",
       "requires_url":false,"default_url":"","models":[]},
      {"id":"ollama","name":"Ollama","tagline":"Local models",
       "requires_url":true,"default_url":"http://localhost:11434","models":[]},
      {"id":"xai","name":"xAI","tagline":"Grok models",
       "requires_url":false,"default_url":"","models":[]}
    ]}
    """.data(using: .utf8)!

    private func decoded() throws -> [Route] {
        try JSONDecoder().decode(ProvidersResponse.self, from: Self.payload)
            .providers.map(\.route)
    }

    private struct StubFetcher: RouteCatalogFetching {
        let result: RouteCatalogState
        func fetch(_ endpoint: GatewayConfig.Endpoint) async -> RouteCatalogState { result }
    }

    private static let endpoint = GatewayConfig.resolved(
        .init(url: URL(string: "http://127.0.0.1:8080")!, token: nil)
    )

    // MARK: - no model versions anywhere in production

    /// THE DEFECT THIS COMMIT REMOVES. Until now the catalogue was eight
    /// literals carrying model versions — `OPUS 4.6`, `GPT-5.2`,
    /// `GEMINI 3.1 PRO`, `GROK 4.1`, `LLAMA 4 MAVERICK`, `DEEPSEEK V4` — baked
    /// into the binary, correctable only by an App Store release, and wrong
    /// the day any provider ships a new version.
    ///
    /// The vacuous form is "the catalogue type exists" or "`Route` has a
    /// `name`", both of which pass with every literal still in place. The
    /// discriminating form reads the SHIPPING SOURCE and fails if any of those
    /// six strings is present anywhere under `Sources/` — including in a
    /// comment that someone pastes back as "parity".
    ///
    /// Reading source from a test is unusual and deliberate: the defect is the
    /// PRESENCE OF A LITERAL, and no runtime value can observe a literal that
    /// was deleted. Only the text can.
    func testNoModelVersionStringSurvivesInShippingSource() throws {
        let sources = URL(fileURLWithPath: #filePath)      // Tests/ZeusTests/RouteTests.swift
            .deletingLastPathComponent()                    // Tests/ZeusTests
            .deletingLastPathComponent()                    // Tests
            .deletingLastPathComponent()                    // repo root
            .appendingPathComponent("Sources/ZeusApp")
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        // POSITIVE CONTROL. If this enumeration is empty or pointed at the
        // wrong directory, every needle below returns "absent" and the leg
        // passes vacuously — the dead-probe-as-clean-zero fault. A known-
        // present needle in the SAME invocation proves the probe ran.
        XCTAssertGreaterThan(files.count, 10, "source enumeration failed — needles below are meaningless")
        let corpus = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(corpus.contains("struct Route"), "POSITIVE CONTROL: corpus is not the app's source")

        for needle in ["OPUS 4.6", "GPT-5.2", "GEMINI 3.1 PRO", "GROK 4.1",
                       "LLAMA 4 MAVERICK", "DEEPSEEK V4"] {
            XCTAssertFalse(corpus.contains(needle),
                           "\(needle) is a model version literal — the catalogue is fetched, not vendored")
        }
    }

    /// The three rows the gateway does not have. `auto` is fiction (`"auto"`
    /// as a provider on `~/Zeus@main`: 0 sites); `groq` and `deepseek` are
    /// absent from the 18 it enumerates. A row for a provider the gateway does
    /// not know is a selection that cannot take effect.
    func testDroppedRowsAreNotReintroducedFromTheProtoype() throws {
        let ids = try decoded().map(\.id)
        XCTAssertFalse(ids.contains("auto"))
        XCTAssertFalse(ids.contains("groq"))
        XCTAssertFalse(ids.contains("deepseek"))
        // NOT VACUOUS: the same decode must yield the ids the gateway does
        // have, or the three assertions above pass on an empty array.
        XCTAssertEqual(ids, ["anthropic", "ollama", "xai"])
    }

    // MARK: - decode + derivation

    /// `name` is the gateway's display name, uppercased for the tracking
    /// convention — and carries NO version. The vacuous form ("name is
    /// non-empty") passes on `ANTHROPIC · OPUS 4.6`.
    func testNameIsTheGatewaysDisplayNameAndCarriesNoVersion() throws {
        let routes = try decoded()
        XCTAssertEqual(routes.map(\.name), ["ANTHROPIC", "OLLAMA", "XAI"])
        for r in routes {
            XCTAssertNil(r.name.rangeOfCharacter(from: .decimalDigits),
                         "a digit in a provider name is a version leaking back in")
        }
    }

    /// `reach` is DERIVED from two fetched fields, so its provenance is
    /// nameable. The vacuous form is "`reach` is one of the two cases", which
    /// passes on `return .direct` — the collapsed function. This asserts the
    /// derivation actually discriminates, and the explicit inequality is what
    /// fails on a collapse.
    func testReachIsDerivedFromFetchedTopologyAndDoesNotCollapse() throws {
        let routes = try decoded()
        let byID = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0.reach) })
        XCTAssertEqual(byID["ollama"], .lanOnly, "a loopback default_url is a LAN node")
        XCTAssertEqual(byID["anthropic"], .direct)
        XCTAssertNotEqual(byID["ollama"], byID["anthropic"],
                          "derive() has collapsed to a constant")
        // requires_url false with a loopback URL must still be .direct: the
        // flag is half the operand and dropping it is a silent widening.
        XCTAssertEqual(Route.Reach.derive(requiresURL: false,
                                          defaultURL: "http://localhost:11434"), .direct)
    }

    /// The prototype's `P50 180MS` never returns. There is no per-route
    /// latency producer: `HTTPTransport` decodes two fields, and the only
    /// millisecond number in the tree describes the whole gateway
    /// (`LinkMonitor:174`).
    func testNoRouteAdvertisesALatencyNothingMeasured() throws {
        for r in try decoded() {
            for needle in ["MS", "P50", "LATENCY"] {
                XCTAssertFalse(r.reach.rawValue.contains(needle),
                               "\(r.id) renders a latency this app never measured")
            }
        }
    }

    // MARK: - the subtitle count follows the fetch

    /// THE PROTOTYPE'S SELF-CONTRADICTION: `ZeusApp.jsx:769` renders
    /// `11 PROVIDERS ENROLLED` immediately above a `.map` over eight. Nothing
    /// computes it.
    ///
    /// The vacuous form `XCTAssertFalse(subtitle.isEmpty)` passes on the
    /// hardcoded 11 — i.e. on the defect itself. The kept form ties the number
    /// to the fetched array's length.
    func testSubtitleCountFollowsTheFetchNotALiteral() throws {
        let routes = try decoded()
        let state = RouteCatalogState.loaded(routes: routes, activeModel: nil)
        XCTAssertEqual(state.subtitle, "3 PROVIDERS ENROLLED")
        XCTAssertFalse(state.subtitle.hasPrefix("11 "),
                       "the prototype's 11 contradicts its own array")
        // A different fetch must produce a different number, or the count is
        // a constant that happens to match.
        XCTAssertEqual(RouteCatalogState.loaded(routes: [routes[0]], activeModel: nil).subtitle,
                       "1 PROVIDERS ENROLLED")
    }

    /// The ONE model string the app may render is the ACTIVE one from
    /// `/v1/status` — a fact about the running process, not a claim about what
    /// any provider serves. Absent means nothing is rendered, not a dash and
    /// not a placeholder: an uncaptioned dash reads as a rendering bug (the
    /// captioned `—` at `HomeView:226` is a different case and stays).
    func testActiveModelRendersOnlyWhenTheGatewaySuppliedIt() {
        XCTAssertEqual(
            RouteCatalogState.loaded(routes: [], activeModel: "claude-opus-5").subtitle,
            "0 PROVIDERS ENROLLED · ACTIVE claude-opus-5")
        let silent = RouteCatalogState.loaded(routes: [], activeModel: nil).subtitle
        XCTAssertFalse(silent.contains("ACTIVE"))
        XCTAssertFalse(silent.contains("—"), "no placeholder for an absent model")
        XCTAssertFalse(RouteCatalogState.loaded(routes: [], activeModel: "").subtitle.contains("ACTIVE"),
                       "an empty string is an absent model, not a renderable one")
    }

    // MARK: - the offline story

    /// THE FAILURE PATH IS WHERE THE DEFECT WOULD COME BACK. Falling back to a
    /// vendored list when the gateway is unreachable reintroduces the hardcoded
    /// catalogue in the one situation nobody tests. Every non-loaded case must
    /// render ZERO rows AND a reason.
    ///
    /// The vacuous form is "`unavailable` has no routes", which passes if
    /// `routes` returns `[]` unconditionally — including for `loaded`. The
    /// last assertion is what fails on that stub.
    func testUnreachableRendersNoRowsAndAReasonNeverAStaleList() {
        let cases: [RouteCatalogState] = [
            .unavailable(reason: "127.0.0.1 · connection refused"),
            .unconfigured("ZEUS_GATEWAY_URL unset"),
        ]
        for state in cases {
            XCTAssertTrue(state.routes.isEmpty, "a stale vendored list on the failure path")
            XCTAssertNotNil(state.emptyReason, "zero rows with no reason reads as a bug")
            XCTAssertFalse(state.emptyReason!.isEmpty)
        }
        // NOT VACUOUS: `routes` must actually carry rows in the loaded case.
        XCTAssertEqual(RouteCatalogState.loaded(routes: [Route(id: "a", name: "A", tagline: "",
                                                              reach: .direct)],
                                               activeModel: nil).routes.count, 1)
        // A loaded-but-empty catalogue is a THIRD thing: the gateway answered
        // and enumerated nothing. It gets its own reason, not silence.
        XCTAssertNotNil(RouteCatalogState.loaded(routes: [], activeModel: nil).emptyReason)
        XCTAssertNil(RouteCatalogState.loaded(routes: [Route(id: "a", name: "A", tagline: "",
                                                            reach: .direct)],
                                              activeModel: nil).emptyReason)
    }

    // MARK: - the store, and the toast that may not say LOCKED

    /// `PUT /v1/config { default_provider }` is DECLINED, so the toast must not
    /// announce an effect on the gateway. The endpoint has a real consumer
    /// (`config_handlers.rs:421-430` can repoint `state.config.model`), which
    /// makes a `LOCKED` toast wrong in both directions: it over-claims on an
    /// unconfigured box (the branch at `:423` is unreachable — measured) and
    /// UNDER-claims on a configured one, where the real effect is bigger than
    /// a row captioned "Route" promises.
    ///
    /// The vacuous form is "select returns a non-empty string". This pins the
    /// scope word and refuses the fabricated one.
    @MainActor
    func testSelectionIsDeviceLocalAndTheToastSaysSo() {
        let store = RouteCatalogStore(config: Self.endpoint,
                                      fetcher: StubFetcher(result: .loading))
        let route = Route(id: "ollama", name: "OLLAMA", tagline: "", reach: .lanOnly)
        let toast = store.select(route)
        XCTAssertEqual(store.selected, route, "the tap must change the selection")
        XCTAssertTrue(toast.contains("THIS DEVICE"), "the toast must name the scope of the effect")
        XCTAssertFalse(toast.contains("LOCKED"),
                       "nothing is locked — the gateway PUT is deliberately not performed")
    }

    /// A selection that survives a refetch into a catalogue that no longer
    /// contains it would render a sheet with NOTHING highlighted and no reason
    /// — indistinguishable from a bug. The vacuous form ("load sets state")
    /// passes without the drop.
    @MainActor
    func testASelectionMissingFromTheNewCatalogueIsDropped() async {
        let gone = Route(id: "groq", name: "GROQ", tagline: "", reach: .direct)
        let kept = Route(id: "ollama", name: "OLLAMA", tagline: "", reach: .lanOnly)
        let store = RouteCatalogStore(
            config: Self.endpoint,
            fetcher: StubFetcher(result: .loaded(routes: [kept], activeModel: nil)))

        store.selected = gone
        await store.load()
        XCTAssertNil(store.selected, "a selection outside the catalogue cannot highlight a row")

        // NOT VACUOUS: a selection that IS present must survive, or `load`
        // simply clears unconditionally.
        store.selected = kept
        await store.load()
        XCTAssertEqual(store.selected, kept)
    }

    /// An unconfigured build must not sit in `loading` forever pretending a
    /// fetch is in flight when none was ever issued.
    @MainActor
    func testUnconfiguredGatewayNamesItselfRatherThanSpinning() async {
        let store = RouteCatalogStore(config: .absent,
                                      fetcher: StubFetcher(result: .loaded(routes: [], activeModel: nil)))
        if case .unconfigured(let why) = store.state {
            XCTAssertTrue(why.contains("ZEUS_GATEWAY_URL"), "the reason must quote the missing input")
        } else {
            XCTFail("an absent config must not present as loading or loaded")
        }
        // And `load` must be a no-op rather than flipping to a fabricated
        // loaded state the stub would happily supply.
        await store.load()
        guard case .unconfigured = store.state else {
            return XCTFail("load() ran a fetch with no endpoint")
        }
    }
}
