import Foundation
import SwiftUI

/// A selectable inference route — **one provider identity, as the gateway
/// names it**.
///
/// ── WHAT THIS FILE USED TO BE, AND WHY IT ISN'T ─────────────────────────
/// Until this commit `RouteCatalog.all` was eight `Route(id:name:reach:)`
/// literals transcribed from `prototypes/ZeusApp.jsx:322-331` at `4798cc2`.
/// Every `name` carried a MODEL VERSION — read the six of them at that
/// citation; they are deliberately NOT quoted here, because
/// `testNoModelVersionStringSurvivesInShippingSource` greps this directory for
/// exactly those strings and a doc comment is part of the corpus. (It caught
/// this file first: the explanation of the removal had pasted all six back.
/// A prohibition that exempts its own rationale is not a prohibition.)
/// Shipped, those names are a claim about which model a provider serves, baked
/// into a binary correctable only by an App Store release, and wrong the day
/// any of them ships a new version. The standing rule is: never hardcode
/// models, pull them from the API.
///
/// So the rows are now FETCHED: `GET {base}/v1/providers`.
///
/// ── WHAT THE FETCH DOES AND DOES NOT BUY ────────────────────────────────
/// Measured live at `127.0.0.1:8080` against `~/Zeus@8746e17e4`, and read in
/// source at `crates/zeus-api/src/handlers/extensions_handlers.rs:381`:
/// `list_providers` reads **no state** — the response body and the `json!`
/// literal in that handler are the same bytes. So the fetch does not make the
/// string *measured*; it makes it **single**. One server-side authority,
/// changeable without an app release. That is the whole benefit and it is
/// worth stating plainly, because "we pull it from the API" reads like a
/// stronger claim than it is.
///
/// ── THREE ROWS DELETED, NOT RENAMED ─────────────────────────────────────
///   * `auto` — `AUTO — NOUS ROUTES`. **The gateway has no such provider.**
///     `"auto"` as a provider or model on `~/Zeus@main`: 0 sites across
///     `zeus-api`/`zeus-llm`/`zeus-core` (the hits are `tool_choice` and an
///     ffmpeg flag). The prototype's first row is fiction.
///   * `groq`, `deepseek` — absent from the 18 the gateway enumerates
///     (`deepseek` in `crates/zeus-api`: 0 files; POS ctl `anthropic`: 9).
/// A row for a provider the gateway does not know is a selection that cannot
/// take effect. Do not restore them from the JSX.
///
/// ── NO LATENCY, STILL ───────────────────────────────────────────────────
/// The prototype's `meta` (`P50 180MS · DIRECT`) stays dropped; see `Reach`.
struct Route: Identifiable, Equatable {

    /// The gateway's provider id (`anthropic`, `ollama`, `xai`, …).
    let id: String

    /// The gateway's DISPLAY name (`Anthropic`, `Ollama`, `xAI`, `MiMo`, …).
    /// Note what is absent: no model version. The response's `models` array is
    /// empty for 15 of 18 providers **by design** — the handler's own docstring
    /// says *"Models are NEVER hardcoded here: the UI fetches live model lists
    /// per provider after credentials are configured (`models` stays empty)"*.
    /// So there is no per-provider model to render, and inventing one here
    /// would re-create exactly the defect this commit removes.
    let name: String

    /// One line of provider context, verbatim from the gateway (`tagline`).
    let tagline: String

    /// How the request leaves this device.
    let reach: Reach

    /// Definitional, not measured — and now **derived from fetched fields**
    /// rather than assigned by hand.
    ///
    /// The prototype's slot held `P50 180MS · DIRECT`: a hardcoded latency in
    /// a mock. This app has no latency instrument for a provider — the only
    /// millisecond number in the tree is `LinkMonitor:174`, one `/health`
    /// round-trip describing the WHOLE gateway, not a route. Rendering a p50
    /// would put a fabricated number in a slot the eye reads as a measurement.
    ///
    /// A per-route latency arm was considered and NOT built: `HTTPTransport`
    /// decodes two fields (`response`, `session_id`), and
    /// `grep -rn "route.*ms\|ms.*route" Sources` is 0. A conditional whose
    /// predicate is structurally unreachable is dead code wearing a policy's
    /// clothes — it reads to the next maintainer as "the plumbing exists, it's
    /// just quiet today". It does not exist. If the gateway ever reports a
    /// real per-route latency it belongs BESIDE `reach`, not instead of it:
    /// one is measured, one is definitional, and collapsing them loses which
    /// is which.
    enum Reach: String, Equatable, CaseIterable {
        /// Straight to the provider over the internet.
        case direct = "DIRECT FROM THIS NODE"
        /// Never leaves the local network.
        case lanOnly = "LAN BY DEFAULT · NO EGRESS"

        /// Derived from the two fetched fields that carry topology.
        ///
        /// A provider that requires a URL AND defaults to a loopback/private
        /// host is a node on this network (`ollama` →
        /// `http://localhost:11434`). Everything else egresses. Both operands
        /// come from the response, so the provenance of the rendered string is
        /// nameable: it is the gateway's own `requires_url` / `default_url`.
        ///
        /// ⚠️ IT IS THE **DEFAULT** URL, AND THE STRING SAYS SO. `default_url`
        /// is the catalogue's default, NOT the URL this gateway is configured
        /// with — the operator may run Ollama on a remote node, and a Tailscale
        /// `100.64.x` host is not in the private-prefix list below either. The
        /// string used to read `LAN ONLY · NO EGRESS`, which over-read the
        /// source by one word: it asserted a fact about the running
        /// deployment from a field that describes the catalogue.
        ///
        /// The alternative — derive from the CONFIGURED url — has no producer:
        /// all 226 leaves of `GET /v1/config` were walked on this box and
        /// there is no `ollama.url`. The only `ollama` paths are
        /// `mnemosyne.ollama_url` (the EMBEDDINGS host — a different subject)
        /// and `default_provider`. So the wording is the fix, not the wiring.
        static func derive(requiresURL: Bool, defaultURL: String) -> Reach {
            guard requiresURL,
                  let host = URLComponents(string: defaultURL)?.host?.lowercased()
            else { return .direct }
            if host == "localhost" || host == "127.0.0.1" || host == "::1"
                || host.hasSuffix(".local")
                || host.hasPrefix("192.168.") || host.hasPrefix("10.") {
                return .lanOnly
            }
            return .direct
        }
    }
}

/// What the NODES tab knows about routes right now.
///
/// Four cases, and the important one is `unavailable`. **There is no vendored
/// fallback list.** When the gateway cannot be reached the sheet renders NO
/// ROWS plus the reason — because falling back to the eight hardcoded routes
/// on the failure path would reintroduce, in the one situation nobody tests,
/// precisely the defect this commit exists to remove. A stale literal is not a
/// degraded mode; it is the same lie with worse timing.
enum RouteCatalogState: Equatable {
    case unconfigured(String)
    case loading
    case loaded(routes: [Route], activeModel: String?)
    case unavailable(reason: String)

    /// The rows to render. Empty in every non-`loaded` case, on purpose.
    var routes: [Route] {
        if case .loaded(let routes, _) = self { return routes }
        return []
    }

    /// The sheet header's second line.
    ///
    /// DERIVED from the fetched count in the loaded case — never a literal.
    /// The prototype renders `11 PROVIDERS ENROLLED` (`ZeusApp.jsx:769`)
    /// directly above a `.map` over an array of **eight**; nothing computes
    /// it. That contradiction is not ported, and the count now follows the
    /// fetch rather than either number.
    var subtitle: String {
        switch self {
        case .unconfigured:            return "NO GATEWAY CONFIGURED"
        case .loading:                 return "READING PROVIDER CATALOGUE…"
        case .unavailable:             return "CATALOGUE UNAVAILABLE"
        case .loaded(let routes, let model):
            let head = "\(routes.count) PROVIDERS ENROLLED"
            // The ONE model string this app may render, and only when the
            // gateway supplied it this fetch: `/v1/status.model` is the
            // ACTIVE model — a fact about the running process, not a claim
            // about what any provider serves. `nil` renders nothing at all.
            guard let model, !model.isEmpty else { return head }
            return head + " · ACTIVE \(model)"
        }
    }

    /// The line rendered INSTEAD OF rows when there are none. Never empty in
    /// the caseless cases, so the operator can always tell an empty list from
    /// a broken one.
    var emptyReason: String? {
        switch self {
        case .loaded(let routes, _):   return routes.isEmpty ? "GATEWAY ENUMERATES NO PROVIDERS" : nil
        case .unconfigured(let why):   return why.uppercased()
        case .loading:                 return nil
        case .unavailable(let reason): return reason.uppercased()
        }
    }
}

// MARK: - the wire

/// `GET /v1/providers` (`crates/zeus-api/src/routes.rs:673`).
struct ProvidersResponse: Decodable {
    let providers: [Provider]

    struct Provider: Decodable {
        let id: String
        let name: String
        let tagline: String
        let requiresURL: Bool
        let defaultURL: String

        enum CodingKeys: String, CodingKey {
            case id, name, tagline
            case requiresURL = "requires_url"
            case defaultURL = "default_url"
        }

        var route: Route {
            Route(id: id, name: name.uppercased(), tagline: tagline.uppercased(),
                  reach: .derive(requiresURL: requiresURL, defaultURL: defaultURL))
        }
    }
}

/// `GET /v1/status`. Only `model` is read; the rest of that payload names this
/// box's workspace and session count and has no business in the UI.
struct StatusResponse: Decodable {
    let model: String?
}

protocol RouteCatalogFetching: Sendable {
    func fetch(_ endpoint: GatewayConfig.Endpoint,
               credentials: CredentialProviding) async -> RouteCatalogState
}

struct HTTPRouteCatalogFetcher: RouteCatalogFetching {

    var timeout: TimeInterval = 6

    private func get<T: Decodable>(_ type: T.Type,
                                   path: String,
                                   endpoint: GatewayConfig.Endpoint,
                                   credentials: CredentialProviding) async throws -> T {
        var request = URLRequest(url: endpoint.url.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        // A cached catalogue would render providers the gateway dropped an
        // hour ago — same reasoning as `LinkMonitor:172`.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let token = credentials.credential(for: endpoint) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "gateway", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func fetch(_ endpoint: GatewayConfig.Endpoint,
               credentials: CredentialProviding) async -> RouteCatalogState {
        do {
            let catalogue = try await get(ProvidersResponse.self,
                                          path: "v1/providers", endpoint: endpoint,
                                          credentials: credentials)
            // The status fetch is SEPARATELY fallible and separately optional:
            // a catalogue that arrived is renderable whether or not the active
            // model did. Folding them into one `try` would blank the whole
            // sheet because a decorative line failed.
            let model = try? await get(StatusResponse.self,
                                       path: "v1/status", endpoint: endpoint,
                                       credentials: credentials).model
            return .loaded(routes: catalogue.providers.map(\.route), activeModel: model)
        } catch {
            return .unavailable(reason: "\(endpoint.url.host ?? "gateway") · \(error.localizedDescription)")
        }
    }
}

@MainActor
final class RouteCatalogStore: ObservableObject {

    @Published private(set) var state: RouteCatalogState

    /// The operator's preferred route. **A device-local preference, and the
    /// UI says so.**
    ///
    /// ── WHY NOT `PUT /v1/config { default_provider }` ───────────────────
    /// The endpoint exists (`routes.rs:313` → `config_handlers.rs:156`) and it
    /// DOES have a consumer — `config_handlers.rs:421-430` writes
    /// `default_provider`, then, *if* `providers[<id>].model` exists, sets
    /// `state.config.model = "<id>/<model>"`. So a tap that PUT it would do
    /// one of two things depending on server-side state the app cannot see:
    ///   * nothing at all, when no provider is configured with a model
    ///     (measured on this box: `~/.zeus/providers.json` is
    ///     `{"default_provider":"ollama"}` — the `providers` key is ABSENT, so
    ///     the branch at `:423` is unreachable and `/v1/status` never moved);
    ///   * or SILENTLY REPOINT THE ACTIVE MODEL, when one is.
    /// A toast that reads the same in both cases fabricates certainty either
    /// way, and the second case is a bigger effect than a row captioned
    /// "Route" promises. So the wire is DECLINED, visibly, rather than left
    /// unnoticed — and the toast may not say LOCKED, because nothing is.
    @Published var selected: Route?

    private let config: GatewayConfig
    private let fetcher: RouteCatalogFetching

    /// See `ApprovalsStore.credentials` — same reason, same precedence, one
    /// provider type for both.
    private let credentials: CredentialProviding

    /// `config` has NO DEFAULT — see `LinkMonitor.init`. This store is built
    /// by `RootView` and handed DOWN to `NodesView`, which used to construct
    /// it itself; a view-owned construction had no store in scope and so
    /// could only ever have read the environment.
    /// `credentials` has NO DEFAULT, deliberately. A default of
    /// `KeychainCredentialProvider()` is not a test double — it is an
    /// unlogged dependency on the HOST's state: on a simulator with an empty
    /// Keychain it answers `nil` to everything, so every "no credential was
    /// attached" leg passes on the empty store rather than on the wiring.
    /// The one live construction is `RootView.swift` (`Sources` census == 1).
    init(config: GatewayConfig,
         fetcher: RouteCatalogFetching = HTTPRouteCatalogFetcher(),
         credentials: CredentialProviding) {
        self.config = config
        self.fetcher = fetcher
        self.credentials = credentials
        switch config {
        case .absent, .malformed:
            self.state = .unconfigured(config.summary)
        case .resolved:
            self.state = .loading
        // The route catalogue is `GET /v1/providers` — an HTTP surface the
        // embedded core does not have. The v1 bridge exports `setProvider` and
        // NO enumeration (`zeus_core_bridge.swift:492-547`), so there is no
        // list to fetch and `.loading` would spin forever against a fetcher
        // that can never be called (`load()` guards on `.resolved`).
        //
        // Reported through `.unconfigured` because that arm means "no catalogue
        // and here is why", which is exactly true — with its own sentence
        // rather than `config.summary`, so the reader is told what is missing
        // instead of where the core is.
        case .local:
            self.state = .unconfigured("local core enumerates no providers yet")
        }
    }

    func load() async {
        guard case .resolved(let endpoint) = config else { return }
        state = .loading
        let next = await fetcher.fetch(endpoint, credentials: credentials)
        state = next
        // A selection that is not in the catalogue we just fetched cannot
        // highlight a row, and the operator cannot tell that from a bug. Drop
        // it rather than render a sheet with nothing selected and no reason.
        if let selected, !next.routes.contains(where: { $0.id == selected.id }) {
            self.selected = nil
        }
    }

    /// What the toast says. Names the scope of the effect, because the effect
    /// is scoped: this device, this install, until relaunch.
    func select(_ route: Route) -> String {
        selected = route
        return "ROUTE PREFERRED — \(route.name) · THIS DEVICE"
    }
}
