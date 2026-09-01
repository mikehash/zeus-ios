import Foundation

/// Where the app looks for a gateway, and what it does when it doesn't find one.
///
/// This type exists so that "no gateway configured" and "gateway configured but
/// wrong" are **different values**, not two spellings of nil. The M4 note stands
/// and generalises here: a stub that answers is indistinguishable from a wired
/// build — and a config that silently defaults is indistinguishable from a config
/// that was actually supplied. Both failures are invisible in the transcript,
/// which is the only surface an operator reads.
///
/// So: no defaults. No `?? "localhost"`. Absent is a case, malformed is a case,
/// and each carries the string that produced it so a receipt can name the input.
enum GatewayConfig: Equatable {

    /// Nothing supplied. Not an error — a fact about this build.
    case absent

    /// Something was supplied and could not be turned into a usable endpoint.
    /// `raw` is carried verbatim so the failure can quote the operand rather
    /// than describe it.
    case malformed(raw: String, reason: MalformedReason)

    /// A usable endpoint.
    case resolved(Endpoint)

    enum MalformedReason: String, Equatable {
        case notAURL          = "not parseable as a URL"
        case missingScheme    = "no scheme (expected http:// or https://)"
        case unsupportedScheme = "scheme is not http or https"
        case missingHost      = "no host component"
    }

    struct Endpoint: Equatable {
        let url: URL
        /// Present only if a token was supplied. Absent is distinct from empty:
        /// an empty token is a *malformed* credential, not a missing one, and
        /// the parser refuses it below rather than sending `Bearer `.
        let token: String?
    }

    // MARK: - Resolution

    /// Keys read from the environment. Named as constants so the census in
    /// `check_membership.sh`-style guards has a single site to count, and so a
    /// rename cannot leave a documentation string behind describing the old one.
    static let urlKey = "ZEUS_GATEWAY_URL"
    static let tokenKey = "ZEUS_GATEWAY_TOKEN"

    /// Resolve from an arbitrary key/value source.
    ///
    /// Takes the environment as a **parameter** rather than reading
    /// `ProcessInfo` directly, because a function that reads global state is
    /// only testable by mutating global state — and a test that mutates the
    /// process environment leaks into every other test in the same process.
    /// The default argument keeps the call site short in production.
    static func resolve(
        from env: [String: String] = ProcessInfo.processInfo.environment
    ) -> GatewayConfig {
        guard let raw = env[urlKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return .absent
        }

        guard let url = URL(string: raw) else {
            return .malformed(raw: raw, reason: .notAURL)
        }
        guard let scheme = url.scheme?.lowercased() else {
            return .malformed(raw: raw, reason: .missingScheme)
        }
        guard scheme == "http" || scheme == "https" else {
            return .malformed(raw: raw, reason: .unsupportedScheme)
        }
        guard let host = url.host, !host.isEmpty else {
            return .malformed(raw: raw, reason: .missingHost)
        }

        // An empty/whitespace token is a supplied-but-useless credential. It is
        // folded to nil here rather than sent as `Bearer `, which a gateway
        // would reject with a 401 that reads like a *wrong* token instead of an
        // absent one — the same wrong-subject error the whole taxonomy exists
        // to prevent.
        let token = env[tokenKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableToken = (token?.isEmpty == false) ? token : nil

        return .resolved(Endpoint(url: url, token: usableToken))
    }

    /// One-line description for a receipt or a transcript. Never includes the
    /// token — the `resolved` arm prints the endpoint only.
    var summary: String {
        switch self {
        case .absent:
            return "\(Self.urlKey) unset"
        case let .malformed(raw, reason):
            return "\(Self.urlKey)=\"\(raw)\" rejected: \(reason.rawValue)"
        case let .resolved(endpoint):
            return "\(endpoint.url.absoluteString) "
                 + (endpoint.token == nil ? "(no token)" : "(token present)")
        }
    }
}
