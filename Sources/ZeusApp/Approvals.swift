import Foundation
import SwiftUI

// MARK: - the wire
//
// `GET /v1/approvals` — `crates/zeus-api/src/routes.rs:722`, handler
// `security_handlers.rs:27`:
//
//     Json(json!(guard.approvals.list_pending()))
//
// The body is a **BARE ARRAY**, not `{"approvals":[…]}`. Measured live on this
// box against `~/Zeus@8746e17e4`: `http 200`, body `[]`.
//
// `PendingApproval` (`approvals.rs:29-36`) carries `id`, `tool_name`, `args`,
// `agent_id`, `created_at`, and a `status` that is an **internally-tagged**
// enum (`approvals.rs:20-27`, `#[serde(tag = "status")]`). Internally tagged
// means the variant does NOT nest: it flattens into the parent. A pending
// approval is
//
//     {"id":…,"tool_name":…,"args":…,"agent_id":…,"created_at":…,"status":"pending"}
//
// and a denied one carries a SIBLING `"reason"` at the same level — not
// `status.reason`. Decoding `status` as a nested object fails. This mattered
// less than it looks on THIS endpoint (`list_pending` filters to `Pending`, so
// `reason` never appears) and would have bitten on the `approval_event` stream,
// which reuses the type and carries resolved ones.

/// One pending tool execution awaiting an operator's answer.
struct Approval: Identifiable, Equatable {

    /// Carried for the POST. **Never rendered** — it is a correlation handle,
    /// not information, and a UUID in a card is noise the eye has to skip.
    let id: String

    /// The tool the agent wants to run, **verbatim**. Empty is possible on the
    /// wire and renders as `TOOL UNNAMED` rather than being inferred from the
    /// args: a guessed name in the title slot is a claim about what will run.
    let toolName: String

    /// The arguments, **compact JSON, verbatim**. Never paraphrased,
    /// summarised, or pretty-printed into something that reads like prose —
    /// the operator is approving these exact bytes.
    let argsJSON: String

    /// Null on the wire when no agent is attributed. Renders **nothing** in
    /// that case — not `unknown`, not a dash: an uncaptioned placeholder in an
    /// attribution slot reads as an identity.
    let agentID: String?

    /// When the gateway recorded the request.
    let createdAt: Date

    /// `"pending"` here by construction (`list_pending` filters), decoded as a
    /// **string** because of the tag flattening above.
    let status: String

    /// The sibling `reason`, present only on denied records off the stream.
    let reason: String?

    var title: String { toolName.isEmpty ? "TOOL UNNAMED" : toolName }

    /// Age against the DEVICE clock.
    ///
    /// ⚠️ `created_at` is stamped by the GATEWAY's clock and rendered against
    /// THIS DEVICE's. The two are not synchronised, and on a phone that has
    /// been asleep the skew can be seconds to minutes. The number is therefore
    /// an approximation of elapsed time, not a measurement of it — which is
    /// tolerable for "how stale is this request" and would not be for anything
    /// the operator counts against `approval_timeout_secs` (1800 on this box).
    func age(now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(createdAt)))
        if s < 60 { return "\(s)S AGO" }
        if s < 3600 { return "\(s / 60)M AGO" }
        return "\(s / 3600)H AGO"
    }
}

// MARK: - decode

/// Enough of a JSON model to re-emit `args` verbatim in a stable key order.
///
/// `args` is `serde_json::Value` on the wire — any shape at all. Decoding it
/// into a Swift struct would require knowing every tool's argument schema,
/// which the app does not and must not know; decoding it into `[String: Any]`
/// costs `Decodable`. So it is kept as a value tree and re-serialised.
indirect enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrepresentable JSON")
    }

    /// Compact, keys sorted so two renders of the same args are the same
    /// string. Sorting is a RENDERING decision and does not alter a value.
    var compact: String {
        switch self {
        case .null:            return "null"
        case .bool(let b):     return b ? "true" : "false"
        case .string(let s):
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        case .number(let d):
            return d == d.rounded() && abs(d) < 1e15
                ? String(Int64(d)) : String(d)
        case .array(let a):
            return "[" + a.map(\.compact).joined(separator: ",") + "]"
        case .object(let o):
            let body = o.keys.sorted().map { k in
                "\"\(k)\":\(o[k]!.compact)"
            }.joined(separator: ",")
            return "{" + body + "}"
        }
    }
}

struct ApprovalRecord: Decodable {
    let id: String
    let toolName: String
    let args: JSONValue?
    let agentID: String?
    let createdAt: String
    let status: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case id, args, status, reason
        case toolName = "tool_name"
        case agentID = "agent_id"
        case createdAt = "created_at"
    }

    /// `nil` when `created_at` will not parse. A record whose age cannot be
    /// stated is still a request that needs answering, so it is kept and the
    /// age slot renders nothing — dropping it would hide a pending approval
    /// because a decorative field was malformed.
    var approval: Approval {
        Approval(id: id,
                 toolName: toolName,
                 argsJSON: args?.compact ?? "{}",
                 agentID: (agentID?.isEmpty == false) ? agentID : nil,
                 createdAt: Self.parse(createdAt) ?? .distantPast,
                 status: status ?? "pending",
                 reason: reason)
    }

    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - state

/// The four conditions this surface can actually be in.
///
/// ── WHY EMPTY AND UNREACHABLE ARE DIFFERENT CASES ───────────────────────
/// The TUI's `approvals_tab.rs:95` is `self.live.unwrap_or(&[])`, where `live`
/// is `Option<&[ApprovalResponse]>`. That single call **collapses `None`
/// (gateway unreachable) and `Some(&[])` (queue empty)** into the same green
/// `✓ no pending approvals` and the same `0 pending approvals` header, and
/// there is no `with_live(None)` test anywhere in that file. "Gateway down ⇒
/// nothing to approve" is the wrong answer with the highest cost on this
/// surface: it is a green reassurance produced by an absence of information.
/// That shape is NOT inherited here — the two are separate cases, they render
/// different strings, and `headerCount` is `nil` (renders nothing) rather than
/// `0` when the count is unknown. `testUnreachableIsNotEmpty` is the leg.
enum ApprovalsState: Equatable {
    case unconfigured(String)
    case loading
    /// `gatingConfigured` is `nil` when `/v1/config` did not answer — unknown,
    /// which is a third thing and not a `false`.
    case loaded(pending: [Approval], gatingConfigured: Bool?)
    case unavailable(reason: String)

    var pending: [Approval] {
        if case .loaded(let p, _) = self { return p }
        return []
    }

    /// The count beside the heading, or `nil` to render **nothing**.
    ///
    /// `nil` on every case where the queue length is not known. A `0` printed
    /// while the gateway is unreachable is a measurement the app did not make.
    var headerCount: String? {
        if case .loaded(let p, _) = self { return String(p.count) }
        return nil
    }

    /// Three strings for three empty-ish conditions, as ruled.
    var emptyLine: String? {
        switch self {
        case .unconfigured(let summary):
            return "NO GATEWAY CONFIGURED — \(summary.uppercased())"
        case .loading:
            return "READING APPROVAL QUEUE…"
        case .unavailable(let reason):
            return "APPROVALS UNREACHABLE — \(reason.uppercased())"
        case .loaded(let pending, let gating):
            guard pending.isEmpty else { return nil }
            // `require_confirmation_for = []` is a REAL and separate
            // condition, not a flavour of "none pending": the queue cannot
            // fill, so "no pending approvals" would imply it might.
            if gating == false {
                return "NOTHING IS GATED — NO TOOL REQUIRES APPROVAL"
            }
            return "NO PENDING APPROVALS"
        }
    }

    /// Whether the empty line is reassuring or a warning. Unreachable is NOT
    /// reassuring, which is the whole point.
    var isReassuring: Bool {
        if case .loaded = self { return true }
        return false
    }
}

// MARK: - fetch + act

protocol ApprovalsServicing: Sendable {
    func fetch(_ endpoint: GatewayConfig.Endpoint) async -> ApprovalsState
    /// Returns the gateway's own answer, rendered. Never reports a dispatch as
    /// an outcome.
    func resolve(id: String, approve: Bool, reason: String?,
                 endpoint: GatewayConfig.Endpoint) async -> String
}

struct HTTPApprovalsService: ApprovalsServicing {

    var timeout: TimeInterval = 6

    private func request(_ path: String, method: String,
                         body: Data?, endpoint: GatewayConfig.Endpoint) -> URLRequest {
        var r = URLRequest(url: endpoint.url.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = timeout
        // A cached approval queue is worse than none: it renders decisions the
        // operator may already have made. Same reasoning as `LinkMonitor:172`.
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let token = endpoint.token {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    func fetch(_ endpoint: GatewayConfig.Endpoint) async -> ApprovalsState {
        do {
            let (data, response) = try await URLSession.shared.data(
                for: request("v1/approvals", method: "GET", body: nil, endpoint: endpoint))
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "gateway", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            let records = try JSONDecoder().decode([ApprovalRecord].self, from: data)
            // Separately fallible and separately optional: a queue that arrived
            // is renderable whether or not the gating config did. `nil` means
            // UNKNOWN and suppresses the stronger "nothing is gated" string.
            let gating = try? await gatingConfigured(endpoint)
            return .loaded(pending: records.map(\.approval), gatingConfigured: gating)
        } catch {
            return .unavailable(
                reason: "\(endpoint.url.host ?? "gateway") · \(error.localizedDescription)")
        }
    }

    private func gatingConfigured(_ endpoint: GatewayConfig.Endpoint) async throws -> Bool {
        let (data, _) = try await URLSession.shared.data(
            for: request("v1/config", method: "GET", body: nil, endpoint: endpoint))
        struct Config: Decodable {
            struct Aegis: Decodable {
                let requireConfirmationFor: [String]?
                enum CodingKeys: String, CodingKey {
                    case requireConfirmationFor = "require_confirmation_for"
                }
            }
            let aegis: Aegis?
        }
        let cfg = try JSONDecoder().decode(Config.self, from: data)
        return !(cfg.aegis?.requireConfirmationFor ?? []).isEmpty
    }

    func resolve(id: String, approve: Bool, reason: String?,
                 endpoint: GatewayConfig.Endpoint) async -> String {
        let path = "v1/approvals/\(id)/\(approve ? "approve" : "deny")"
        var body: Data?
        if !approve, let reason, !reason.isEmpty {
            body = try? JSONSerialization.data(withJSONObject: ["reason": reason])
        }
        do {
            let (data, response) = try await URLSession.shared.data(
                for: request(path, method: "POST", body: body, endpoint: endpoint))
            let http = response as? HTTPURLResponse
            return Self.outcome(status: http?.statusCode ?? 0, body: data, approve: approve)
        } catch {
            // A POST that never arrived is NOT a denial and NOT an approval.
            return "NOT SENT — \(error.localizedDescription.uppercased())"
        }
    }

    /// What the toast says, derived from what the gateway answered.
    ///
    /// The 404 has TWO causes and they are different events for the operator:
    /// `Approval 'x' not found` (never existed / already garbage-collected) vs
    /// `Approval 'x' is no longer pending` (someone else, or a timeout, already
    /// answered it). Collapsing them into "failed" loses the one fact the
    /// operator needs — whether their decision was superseded. So the
    /// gateway's own `error` string is surfaced rather than replaced.
    static func outcome(status: Int, body: Data, approve: Bool) -> String {
        struct Err: Decodable { let error: String? }
        if (200..<300).contains(status) {
            return approve ? "APPROVED — GATEWAY ACCEPTED" : "DENIED — GATEWAY ACCEPTED"
        }
        let detail = (try? JSONDecoder().decode(Err.self, from: body))?.error
        return "NOT APPLIED — \(( detail ?? "HTTP \(status)").uppercased())"
    }
}

// MARK: - store

@MainActor
final class ApprovalsStore: ObservableObject {

    @Published private(set) var state: ApprovalsState
    /// Last toast. Reports the gateway's ANSWER, never the fact that a request
    /// was dispatched — a POST that left the device is not an outcome.
    @Published var lastOutcome: String?

    private let config: GatewayConfig
    private let service: ApprovalsServicing

    init(config: GatewayConfig = GatewayConfig.resolveFromEnvironment(),
         service: ApprovalsServicing = HTTPApprovalsService()) {
        self.config = config
        self.service = service
        switch config {
        case .absent, .malformed: self.state = .unconfigured(config.summary)
        case .resolved:           self.state = .loading
        // An approval is a request from an AGENT LOOP to run a tool. The
        // embedded core has no agent loop until zeus107's `automation` feature
        // gate lands, so `.local` cannot produce one — this is emptiness by
        // construction, not an empty list from a gateway that might fill it.
        //
        // Said in its own words rather than `config.summary`: the operator
        // needs "nothing can arrive here yet", not "the core is in-process".
        case .local:
            self.state = .unconfigured("local core has no agent loop yet")
        }
    }

    func load() async {
        guard case .resolved(let endpoint) = config else { return }
        state = .loading
        state = await service.fetch(endpoint)
    }

    func resolve(_ approval: Approval, approve: Bool, reason: String? = nil) async {
        guard case .resolved(let endpoint) = config else { return }
        lastOutcome = await service.resolve(id: approval.id, approve: approve,
                                            reason: reason, endpoint: endpoint)
        // Re-read rather than mutating locally: the local list is a picture of
        // the gateway's queue, and after an answer the gateway is the only
        // thing that knows what is left in it.
        await load()
    }
}

// MARK: - the card

struct ApprovalCard: View {
    let approval: Approval
    let now: Date
    let onApprove: () -> Void
    let onDeny: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(approval.title)
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(Theme.w(0.92))
                    .lineLimit(Theme.lineLimit(1, accessibilitySize: false))
                Spacer(minLength: 0)
                Text(approval.age(now: now))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.w(0.45))
            }

            // Verbatim. The operator is approving these exact bytes; a
            // paraphrase in this slot is a different request than the one that
            // will run.
            Text(approval.argsJSON)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.w(0.62))
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
                .onTapGesture { expanded.toggle() }

            // Renders NOTHING when unattributed — no "unknown", no dash.
            if let agent = approval.agentID {
                Text(agent.uppercased())
                    .font(Theme.mono(8.5))
                    .tracking(1.0)
                    .foregroundStyle(Theme.w(0.4))
            }

            HStack(spacing: 10) {
                Button(action: onApprove) {
                    Text("APPROVE")
                        .font(Theme.mono(10, .semibold))
                        .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
                }
                .foregroundStyle(Theme.accent)
                Button(action: onDeny) {
                    Text("DENY")
                        .font(Theme.mono(10, .semibold))
                        .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
                }
                .foregroundStyle(Theme.w(0.6))
            }
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval request: \(approval.title)")
    }
}

struct ApprovalsSection: View {
    @ObservedObject var store: ApprovalsStore
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("APPROVALS")
                    .font(Theme.mono(8.5, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.w(0.5))
                // Renders nothing at all when the count is unknown.
                if let count = store.state.headerCount {
                    Text(count)
                        .font(Theme.mono(9, .semibold))
                        .foregroundStyle(Theme.w(0.45))
                }
                Spacer(minLength: 0)
            }

            if let line = store.state.emptyLine {
                Text(line)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(store.state.isReassuring ? Theme.w(0.5) : Theme.warn)
                    .lineLimit(Theme.lineLimit(2, accessibilitySize: false))
            } else {
                ForEach(store.state.pending) { approval in
                    ApprovalCard(approval: approval, now: now,
                                 onApprove: { Task { await store.resolve(approval, approve: true) } },
                                 onDeny: { Task { await store.resolve(approval, approve: false) } })
                }
            }

            if let outcome = store.lastOutcome {
                Text(outcome)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.w(0.55))
            }
        }
    }
}
