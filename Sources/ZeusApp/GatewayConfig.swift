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

    /// WHO supplied the endpoint. Carried on the value, not inferred at the
    /// render site, because the two sources are indistinguishable once the URL
    /// is parsed — and an operator who types a URL into commissioning while an
    /// `ENV` override is winning sees nothing change and concludes the field is
    /// broken. Provenance is the only thing that makes that cell legible.
    ///
    /// There is deliberately NO default value for this on `Endpoint.init`. A
    /// default would let a future construction site claim `.environment`
    /// silently, which is the silent-default defect this whole type was written
    /// to delete — one enum case further in.
    enum Source: String, Equatable {
        case environment    // ZEUS_GATEWAY_URL in the process environment
        case commissioning  // typed by the operator, persisted in CommissionStore
    }

    struct Endpoint: Equatable {
        let url: URL
        /// Present only if a token was supplied. Absent is distinct from empty:
        /// an empty token is a *malformed* credential, not a missing one, and
        /// the parser refuses it below rather than sending `Bearer `.
        let token: String?
        /// Where `url` came from. See `Source`.
        let source: Source
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
        let raw = env[urlKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = env[tokenKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return parse(raw: raw, token: token, source: .environment)
    }

    /// The parser, source-agnostic. Split out of `resolve(from:)` so that a
    /// second supplier (the persisted commissioning value) reaches the SAME
    /// validation rather than a second copy of it — two parsers is how one
    /// source starts accepting a URL the other rejects, and the divergence is
    /// invisible until an operator hits the cell where they disagree.
    ///
    /// `source` is a parameter with no default: every caller states who it is.
    static func parse(
        raw rawInput: String?,
        token tokenInput: String?,
        source: Source
    ) -> GatewayConfig {
        guard let raw = rawInput?.trimmingCharacters(in: .whitespacesAndNewlines),
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
        let trimmedToken = tokenInput?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableToken = (trimmedToken?.isEmpty == false) ? trimmedToken : nil

        return .resolved(Endpoint(url: url, token: usableToken, source: source))
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
            // The source is named here and not only on the LINK surface: a
            // transcript that says which host was used but not who supplied it
            // cannot distinguish a desk build's env override from the value the
            // operator typed on the phone.
            return "\(endpoint.url.absoluteString) "
                 + (endpoint.token == nil ? "(no token)" : "(token present)")
                 + " [\(endpoint.source.rawValue)]"
        }
    }
}
