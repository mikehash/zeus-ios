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
    ///
    /// **This arm means NOTHING IS LISTENING**, and it kept that meaning
    /// through the embedded-gateway cut. It was tempting to re-point it at the
    /// local core — "no remote gateway set" and "run locally" describe the same
    /// tap-through — and that would have been the smaller diff and the bigger
    /// lie: the arm that asserts the app cannot work cannot become the arm
    /// where it does. Twelve tests stand on this meaning and still test what
    /// they were written to test. `.local` is a new value, below.
    case absent

    /// The gateway runs IN THIS PROCESS — the Rust core linked as a static
    /// archive, reached through `EmbeddedTransport`. No endpoint, no network.
    ///
    /// ## The third state, and why it is a value rather than a runtime failure
    ///
    /// Local-vs-remote is not binary. `ZeusCore.send` returns
    /// `BridgeError::NoProvider` unless `setProvider` has run, so "local" with
    /// no key is a real, reachable, *third* condition — and if it were only
    /// discoverable by sending, the operator would learn about it as a failed
    /// turn in the transcript. A configuration fact should be RENDERED BEFORE
    /// THE FIRST SEND, not thrown at the first send.
    ///
    /// So the readiness is carried in the value: `.local(.ready)` arms the
    /// composer, `.local(.noProvider)` disarms it and says
    /// `NO PROVIDER — SET ONE IN ROUTES`. `BridgeError::NoProvider` remains
    /// wired as a backstop (`EmbeddedTransport.describe`) with the same words,
    /// so the two cannot drift into two explanations of one state — but on the
    /// intended path it is unreachable.
    case local(LocalReadiness)

    /// Whether the embedded core has a route to a model yet.
    enum LocalReadiness: String, Equatable {
        /// A provider and key are set; a send will reach a model.
        case ready
        /// The core is live and has no provider. The composer is disarmed.
        case noProvider
    }

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

    /// WHICH source produced the config — carried beside it, never inferred.
    ///
    /// The precedence below puts the environment on top of the operator's
    /// persisted choice, which is a debugging trap unless the winner is
    /// VISIBLE: an operator who chose REMOTE in the fork screen and is
    /// silently running against `ZEUS_GATEWAY_URL` from a scheme argument sees
    /// a correct app doing something he did not ask for. So resolution returns
    /// a `Resolution`, not a bare config, and the LINK surface names the
    /// source. A precedence rule with no provenance is a correct answer to a
    /// question the operator cannot ask.
    enum Source: String, Equatable {
        /// `ZEUS_GATEWAY_URL` was set. Wins over everything.
        case environment
        /// The persisted `Commission` decided it (LOCAL or REMOTE).
        case commission
        /// Neither. The config is `.absent`.
        case unset
    }

    /// A config and the source that produced it.
    struct Resolution: Equatable {
        let config: GatewayConfig
        let source: Source
    }


    /// Resolve from the environment ALONE.
    ///
    /// Takes the environment as a **parameter** rather than reading
    /// `ProcessInfo` directly, because a function that reads global state is
    /// only testable by mutating global state — and a test that mutates the
    /// process environment leaks into every other test in the same process.
    ///
    /// ## This is one HALF of resolution and it is going away
    ///
    /// It reads no `Commission`, so it can never return `.local` — the arm
    /// with no producer that this seam exists to give one. It survives this
    /// commit ONLY so the five production call sites keep compiling between
    /// step ① (this seam) and step ② (the sites), and step ② deletes it. It
    /// is not a supported production path: `resolve(from:store:)` below is.
    static func resolveFromEnvironment(
        from env: [String: String] = ProcessInfo.processInfo.environment
    ) -> GatewayConfig {
        guard let raw = env[urlKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return .absent
        }
        return parseEndpoint(raw: raw, token: env[tokenKey])
    }

    /// Turn a raw endpoint string + optional token into a config. **The ONLY
    /// parser in this type**, and both arms of `resolve(from:store:)` call it.
    ///
    /// ## Why an extraction rather than "the same validation as env"
    ///
    /// Written literally, "the REMOTE arm validates the way the environment
    /// does" is a SECOND PARSER — and two parsers agree until one of them is
    /// edited. The divergence would then be invisible: both arms return a
    /// `GatewayConfig`, both compile, and the only symptom is that a string
    /// the environment rejects is accepted from the fork screen (or the
    /// reverse), which nothing in the transcript distinguishes from a correct
    /// resolution. One function, two named call sites, and a test asserting
    /// the two paths agree on the SAME malformed input — an equality between
    /// the paths, not two tables that happen to match.
    ///
    /// ## Production callers — a census, not a promise
    ///
    /// Exactly two, both in this file: `resolveFromEnvironment` above and the
    /// REMOTE arm of `resolve(from:store:)` below. A pure function extracted
    /// for testability acquires no producer by default, and an extraction with
    /// one arm quietly re-inlined is indistinguishable from this one at the
    /// type. `GatewayConfigTests` counts the call sites for that reason.
    static func parseEndpoint(raw: String, token: String?) -> GatewayConfig {
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
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableToken = (trimmed?.isEmpty == false) ? trimmed : nil

        return .resolved(Endpoint(url: url, token: usableToken))
    }

    /// Resolve from the environment AND the operator's persisted choice.
    ///
    /// ## Precedence, stated at the type
    ///
    /// 1. `ZEUS_GATEWAY_URL` in `env` — **wins**, source `.environment`.
    /// 2. A persisted `Commission` — source `.commission`.
    /// 3. Neither — `.absent`, source `.unset`.
    ///
    /// The environment sits on top because it is the EXPLICIT, per-launch
    /// operand: a build-time override that a persisted preference could
    /// silently beat is a debugging trap — you set the variable, the app
    /// ignores it, and nothing on screen says why. The cost of that ordering
    /// is paid by returning `Resolution` rather than a bare config, so the
    /// LINK surface can say WHICH source won.
    ///
    /// ## The store parameter has NO default, deliberately
    ///
    /// A `UserDefaultsCommissionStore()` default here would silently bypass
    /// the seeded `InMemoryCommissionStore` that `ZeusApp` builds for capture
    /// and test launches (`ZeusApp.swift:31-35`): the harness would seed LOCAL
    /// and the resolver would read the phone's real defaults, so every
    /// captured frame would be a lie with green legs beneath it. Making the
    /// store un-defaultable is what turns that from discouraged into
    /// unrepresentable. The callers pass the store the app already injects.
    static func resolve(
        from env: [String: String],
        store: CommissionStoring
    ) -> Resolution {
        let fromEnv = resolveFromEnvironment(from: env)

        // `.malformed` from the environment stays `.environment`-sourced: the
        // operator supplied that string, and falling through to the commission
        // would repair his typo behind his back and report success.
        if fromEnv != .absent {
            return Resolution(config: fromEnv, source: .environment)
        }

        guard let commission = store.load() else {
            return Resolution(config: .absent, source: .unset)
        }

        // The fork choice, landed where ② promised it would land.
        //
        // `nil` is NOT a third mode: it is a record written before the fork
        // screen existed. Every such record resolved `.local` at ② — that is
        // observed behaviour of the shipped build, not a default invented
        // here — so it keeps resolving `.local` and does not re-onboard.
        switch commission.deployment {
        case .remote:
            // The operator chose REMOTE and has not supplied an endpoint yet.
            // `.absent` is the honest arm: its documented meaning is NOTHING
            // IS LISTENING, which is exactly true of a remote deployment with
            // no URL. Source stays `.commission` because the commission IS
            // what decided it — a `.unset` here would say "nobody chose", and
            // somebody did.
            guard let raw = commission.gatewayURL?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return Resolution(config: .absent, source: .commission)
            }
            // Token is nil until the Keychain store has a production
            // construction site. That surface is live in the G0 editor cut and
            // is NOT stubbed here: a token read from an in-memory dictionary
            // would resolve `(token present)` for a credential no operator
            // ever entered.
            return Resolution(config: parseEndpoint(raw: raw, token: nil),
                              source: .commission)

        case .local, .none:
            // Readiness comes from the provider the routes step wrote. No
            // provider is not a broken install; it is `.local(.noProvider)`,
            // rendered before the first send instead of thrown at it.
            let readiness: LocalReadiness =
                (commission.provider == nil) ? .noProvider : .ready
            return Resolution(config: .local(readiness), source: .commission)
        }
    }

    /// One-line description for a receipt or a transcript. Never includes the
    /// token — the `resolved` arm prints the endpoint only.
    /// The one sentence shown when the local core has no provider.
    ///
    /// A constant because it is said in TWO places — the disarmed composer and
    /// the `BridgeError::NoProvider` backstop — and two spellings of one state
    /// is how an operator ends up believing they are two states.
    static let noProviderMessage = "NO PROVIDER — SET ONE IN ROUTES"

    /// Why the composer must be disarmed, or `nil` if it should be armed.
    ///
    /// EXHAUSTIVE with no `default`, so a fifth config case cannot be added
    /// without deciding whether it can send.
    ///
    /// Only `.local(.noProvider)` disarms. The unwired arms (`.absent`,
    /// `.malformed`) deliberately DO NOT: their transports fail loudly on
    /// send, and that failure landing in the transcript is the designed signal
    /// — disarming them would hide a broken build behind a greyed-out button.
    /// `.local(.noProvider)` is different in kind: it is not a broken build,
    /// it is an unfinished setup with a known next action, and the operator
    /// can act on it.
    var disarmReason: String? {
        switch self {
        case .local(.noProvider):     return Self.noProviderMessage
        case .local(.ready):          return nil
        case .absent:                 return nil
        case .malformed:              return nil
        case .resolved:               return nil
        }
    }

    var summary: String {
        switch self {
        case .absent:
            return "\(Self.urlKey) unset"
        case .local(.ready):
            return "local core (in-process)"
        case .local(.noProvider):
            return "local core (in-process, no provider)"
        case let .malformed(raw, reason):
            return "\(Self.urlKey)=\"\(raw)\" rejected: \(reason.rawValue)"
        case let .resolved(endpoint):
            // PRESENCE-ONLY READER of `endpoint.token`, and the ONLY one
            // outside the credential provider. It prints a BOOLEAN about the
            // config, never the bytes — the same contract `GatewayTokenStore`
            // keeps with its `kSecReturnData`-less read.
            //
            // WHY NOT "(no token)": under the credential seam
            // `endpoint.token == nil` no longer means the request will carry
            // nothing — a Keychain-backed remote resolves with a nil endpoint
            // token and still sends a bearer. `summary` is a pure function of
            // the CONFIG, so it may only say what the config knows: the env
            // carried one, or silence. The KEYCHAIN/none word belongs to the
            // provider and is composed at the LINK surface, not here.
            //
            // The space rides INSIDE the suffix: an empty false arm on a
            // trailing-space prefix renders "http://a.b " with a dangling
            // space into `Text(config.summary)`.
            return endpoint.url.absoluteString
                 + (endpoint.token == nil ? "" : " (env token)")
        }
    }
}
