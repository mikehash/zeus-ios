import Foundation

/// The REMOTE conformer — sessions and replay over a Zeus gateway's REST API.
///
/// ── Scope: two methods, and the other six deliberately throw ────────────
///
/// This commit carries `sessions()` and `messages(_:)` and nothing else. The
/// other six are `unimplemented` rather than silently wrong, because each has a
/// surface that reads its answer as a FACT: `hasProvider` feeds a READY badge,
/// `indexSize` feeds a row whose whole subject is zero-versus-unknown, and
/// `search` returning `[]` is read by `Recall.findSummary` as "asked and got
/// nothing". A conformer that invented any of those would render a working
/// feature over a backend that was never asked.
///
/// ── Why replay and NOT `GET /v1/sessions/:id` ──────────────────────────
///
/// Measured at `8e19318c`, `crates/zeus-api/src/handlers/sessions.rs`:
///
/// ```
/// :223  "role": format!("{:?}", m.role)      ← Debug: "Tool", "User", "Assistant"
/// :619  let role = match msg.role { … Role::Tool => "tool" }   ← replay, lowercase
/// ```
///
/// `Role` carries `#[serde(rename_all = "lowercase")]`, but `Debug` does not
/// consult serde attributes. `History.rows` switches on `"user"/"assistant"/
/// "tool"` with a `default: continue` arm, so every row from `get_session`
/// would be silently DROPPED and a full transcript would render as
/// `THIS SESSION HAS NO TURNS`. Two routes in one file disagree about a wire
/// spelling; replay is the one that agrees with the app.
///
/// Replay is also the only route that carries the join source at all —
/// `tool_calls` count in the `get_session` handler: 0.
struct GatewayCapabilities: SessionCapabilities {

    let endpoint: GatewayConfig.Endpoint
    let session: URLSession

    /// The SAME Keychain reader `HTTPTransport:144` uses. Injected, not
    /// defaulted: one credential path, not two, and a call site must not be
    /// able to construct this with a different precedence than the wire the
    /// operator already armed.
    let credentials: CredentialProviding

    init(endpoint: GatewayConfig.Endpoint,
         credentials: CredentialProviding,
         session: URLSession = .shared) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.session = session
    }

    // MARK: - errors

    enum GatewayError: Error, CustomStringConvertible, Equatable {
        /// The route answered 404. Named with its path, per the S1 ruling: a
        /// version string says WHICH gateway, it cannot say why one route is
        /// absent.
        case endpointMissing(path: String)
        case httpStatus(code: Int, path: String)
        case unreachable(host: String, detail: String)
        case malformedResponse(detail: String)
        /// A method this conformer does not implement yet. Distinct from every
        /// error above: those describe a gateway, this describes the APP.
        case unimplemented(method: String)

        var description: String {
            switch self {
            case let .endpointMissing(path):
                return "ENDPOINT MISSING: \(path)"
            case let .httpStatus(code, path):
                return "GATEWAY \(code) ON \(path)"
            case let .unreachable(host, detail):
                return "UNREACHABLE: \(host) — \(detail)"
            case let .malformedResponse(detail):
                return "GATEWAY SENT SOMETHING UNREADABLE — \(detail)"
            case let .unimplemented(method):
                return "NOT AVAILABLE ON A REMOTE GATEWAY: \(method)"
            }
        }
    }

    // MARK: - the two implemented methods

    func sessions() async throws -> [SessionRow] {
        let payload: SessionListPayload = try await get("/v1/sessions")
        return Self.rows(from: payload)
    }

    /// The list mapping, as a `static` over the decoded payload.
    ///
    /// Extracted so a leg can call THE MAPPING ITSELF rather than re-typing it.
    /// Measured: the first version of that leg built its own
    /// `SessionRow(id:sortKey: nil)` from the decoded payload and therefore
    /// passed a mutation that wrote a `""` sentinel here — a test that
    /// re-implements its subject can only detect changes in the copy.
    ///
    /// `sortKey: nil`, for every row, always. `GET /v1/sessions` emits
    /// `created` and no `updated` (`"updated"` ×0 in that handler at
    /// `8e19318c`), so there is no honest key to send — and a creation time
    /// written into the sort would order the operator's history by the wrong
    /// fact with every leg green.
    static func rows(from payload: SessionListPayload) -> [SessionRow] {
        payload.sessions.map { SessionRow(id: $0.id, sortKey: nil) }
    }

    func messages(sessionID: String) async throws -> [TurnMessage] {
        let path = "/v1/sessions/\(sessionID)/replay"
        let payload: ReplayPayload = try await get(path)
        return Self.turns(from: payload.entries)
    }

    // MARK: - the six this commit does not carry

    func hasProvider() async throws -> Bool { false }
    func indexSize() -> UInt32? { nil }
    func listModels(id: String, key: String, baseURL: String?) throws -> [String] {
        throw GatewayError.unimplemented(method: "listModels")
    }
    func remember(fact: String) throws {
        throw GatewayError.unimplemented(method: "remember")
    }
    func search(query: String) -> [SearchHit] { [] }
    func setProvider(id: String, model: String, key: String, baseURL: String?) throws {
        throw GatewayError.unimplemented(method: "setProvider")
    }

    // MARK: - the decoder's join

    /// Replay entries → `[TurnMessage]`, with the tool name joined in.
    ///
    /// ── Why the join lives HERE and not after decode ────────────────────
    ///
    /// The name is on the ASSISTANT entry (`tool_calls[].name`) and the call id
    /// that selects it is on the TOOL entry (`tool_results[].call_id`).
    /// `TurnMessage` has no field that can carry a call id, so once an entry is
    /// a `TurnMessage` the join is no longer possible. It has to happen while
    /// the wire shape is still in hand.
    ///
    /// ── Three substrate facts this depends on, all measured at `8e19318c` ──
    ///
    ///  1. `tool_name` on a TOOL entry is ALWAYS `null`: `Message::tool` sets
    ///     `tool_calls: vec![]` (`zeus-core/src/lib.rs:9617`) and
    ///     `build_replay_entry:626` emits `Null` when that vector is empty. So
    ///     reading `tool_name` off the tool row yields nothing, every time —
    ///     the join is not an optimisation, it is the only route to the name.
    ///  2. `tool_name` is an ARRAY when present (`:627` maps over `tool_calls`),
    ///     so a `String?` decode fails on every tool-calling turn.
    ///  3. All three of `tool_calls`, `tool_name`, `tool_results` are `null`
    ///     rather than `[]` on a prose turn, so every one must be `[T]?`.
    ///
    /// A tool entry whose call id matches nothing degrades to `toolName: nil`,
    /// which `History.rows` renders `[TOOL]` — the same single implementation
    /// the embedded path uses. Never a mis-attribution.
    static func turns(from entries: [ReplayEntry]) -> [TurnMessage] {
        /// `id → name`, accumulated as we walk forward. Every assistant entry
        /// contributes its calls, so a tool entry looks up a name that was
        /// necessarily emitted before it.
        var names: [String: String] = [:]
        var out: [TurnMessage] = []

        for entry in entries {
            for call in entry.tool_calls ?? [] {
                names[call.id] = call.name
            }
            // The bridge's `messages()` does not surface system turns
            // (`lib.rs:1045`), and replay does (`sessions.rs:622`). Dropped
            // here so the two paths produce the SAME `[TurnMessage]` for the
            // same session — which is what the conformance fixture asserts.
            // `History.rows` would drop it anyway through its unknown-role
            // arm, so this is about fixture agreement, not about the screen.
            guard entry.role != "system" else { continue }

            let joined: String? = entry.tool_results?
                .first
                .flatMap { names[$0.call_id] }

            out.append(TurnMessage(role: entry.role,
                                   content: entry.content,
                                   timestampRfc3339: entry.timestamp,
                                   toolName: joined))
        }
        return out
    }

    // MARK: - the wire shapes

    struct SessionListPayload: Decodable {
        struct Item: Decodable { let id: String }
        let sessions: [Item]
    }

    struct ReplayEntry: Decodable {
        struct Call: Decodable { let id: String; let name: String }
        struct Result: Decodable { let call_id: String }
        let role: String
        let content: String
        let timestamp: String
        /// `[T]?` on all three, per fact 3 above. `[T]` fails to decode on
        /// every non-tool message, which is most of them.
        let tool_calls: [Call]?
        let tool_results: [Result]?
    }

    struct ReplayPayload: Decodable {
        let entries: [ReplayEntry]
    }

    // MARK: - transport

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: endpoint.url.appendingPathComponent(path))
        request.httpMethod = "GET"
        // Same bearer path as `HTTPTransport:144` — one Keychain reader.
        if let token = credentials.credential(for: endpoint) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GatewayError.unreachable(
                host: endpoint.url.host ?? endpoint.url.absoluteString,
                detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GatewayError.malformedResponse(detail: "response was not HTTP")
        }
        // 404 is its own arm, not a status code: a route the app needs and the
        // gateway does not serve is a PARITY fact the operator can act on.
        guard http.statusCode != 404 else {
            throw GatewayError.endpointMissing(path: path)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayError.httpStatus(code: http.statusCode, path: path)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GatewayError.malformedResponse(detail: "\(error)")
        }
    }
}
