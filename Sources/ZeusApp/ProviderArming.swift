import Foundation

/// Arming the in-process core, and measuring readiness ON the core.
///
/// ## The incident this file exists for
///
/// `GatewayConfig.resolve` derived `.local(.ready)` from
/// `commission.provider == nil` — a STRING ON DISK. The core's
/// `Mutex<Option<Arc<LlmClient>>>` was `None` for the life of the process
/// because nothing in `Sources/ZeusApp` ever called `setProvider` (census at
/// `485fbcd`: production callers 0). So the console rendered READY over an
/// unarmed core and every send returned `BridgeError::NoProvider`. The value
/// was true; its SUBJECT was wrong.
///
/// ## Why readiness is COMPOSED here rather than folded into `resolve`
///
/// `GatewayConfig.resolve(from:store:)` is a pure function over
/// (environment, commission) — that purity was ruled deliberately when
/// credential attachment moved to `CredentialProviding`, and it has 15 call
/// sites, 12 of them tests. Reaching `EmbeddedCore.shared` from inside it
/// would construct a `tokio` runtime and scan a workspace file index in
/// twelve tests whose subject is string parsing.
///
/// So the core's answer arrives as a SECOND step: `withCoreReadiness(_:)`
/// takes a `Resolution` and returns one whose `.local` arm is measured on the
/// core. `RootView` composes the two.
///
/// LIMIT, STATED: `resolve` alone still answers from the commission. That is
/// safe only while the production caller composes, and the census leg
/// (`ProviderArmingTests.testTheProductionPathComposesCoreReadiness`) is what
/// keeps it true — a weaker instrument than a type change, named as such.
protocol ProviderArming {
    /// Whether THIS core can send: the `Option` `send` reads, not the record
    /// the operator wrote. Never "did the operator pick a provider".
    var isArmed: Bool { get }
}

/// The production conformer: the one embedded core the app links.
struct EmbeddedCoreArming: ProviderArming {
    let core: ZeusCoreProtocol?

    /// `nil` core = the bridge failed to initialise at all. That is not armed,
    /// and it is not the same failure as "no provider" — `makeTransport`
    /// already renders the init error verbatim, so this reports only the arm
    /// state and leaves the naming to the transport.
    var isArmed: Bool { core?.hasProvider() ?? false }
}

extension GatewayConfig.Resolution {
    /// Re-derive the `.local` readiness arm from the CORE.
    ///
    /// `.resolved` / `.absent` / `.malformed` pass through untouched: those
    /// arms describe a REMOTE gateway, where provider selection happens on the
    /// far side and this process's core is not the subject.
    func withCoreReadiness(_ arming: ProviderArming) -> GatewayConfig.Resolution {
        guard case .local = config else { return self }
        return GatewayConfig.Resolution(
            config: .local(arming.isArmed ? .ready : .noProvider),
            source: source
        )
    }
}

/// The one production call that hands the core a provider.
enum CoreArming {

    /// Ollama takes a key it does not check — but the core REFUSES an empty
    /// one.
    ///
    /// `LlmClient::with_api_key` (zeus-llm:1376-1384) rejects `""` because an
    /// empty key produces a malformed `Authorization` header and a 401 that
    /// names the wrong cause. Its docstring states Ollama accepts a key so an
    /// authenticating proxy in front of it is served. So the local arm must
    /// send SOMETHING, and this is that something: a placeholder the local
    /// daemon ignores.
    ///
    /// IT IS NOT A SECRET AND MUST NEVER BE TREATED AS ONE — it is a literal
    /// in a shipped binary. It retires when the core excepts `AuthMethod::None`
    /// providers from the empty-key guard (owned on main, freebsd) and the pin
    /// moves.
    static let ollamaKeyPlaceholder = "ollama-local"

    /// Providers whose key is a placeholder rather than a credential.
    ///
    /// A SET, not an `if id == "ollama"`, so adding a second keyless provider
    /// is one line here instead of a second branch that can disagree with this
    /// one about what "keyless" means.
    static let keylessProviders: Set<String> = ["ollama"]

    /// Why the core could not be armed, or `nil` when it was.
    ///
    /// Returns a REASON rather than a `Bool` because "no provider chosen",
    /// "no key for a keyed provider" and "the core rejected the id" are three
    /// different states and a single false renders them identically.
    @discardableResult
    static func arm(commission: Commission?,
                    core: ZeusCoreProtocol?,
                    providerKey: String?,
                    baseURL: String?) -> String? {
        guard let core else { return "the embedded core failed to initialise" }
        guard let commission, let id = commission.provider else {
            return GatewayConfig.noProviderMessage
        }
        // A model is required by the bridge signature. `nil` here is not a
        // defaultable field: it means ROUTES never obtained a model list, and
        // inventing one would send the core a model name no provider serves.
        guard let model = commission.model else {
            return "NO MODEL — \(ProviderCatalog.label(for: id)) LISTED NONE"
        }
        let key: String?
        if keylessProviders.contains(id) {
            key = ollamaKeyPlaceholder
        } else {
            key = providerKey
        }
        guard let key, !key.isEmpty else {
            return "NO KEY FOR \(ProviderCatalog.label(for: id)) — ENTER ONE IN ROUTES"
        }
        do {
            try core.setProvider(id: id, model: model, key: key, baseUrl: baseURL)
            return nil
        } catch {
            return "\(ProviderCatalog.label(for: id)) REFUSED: \(error)"
        }
    }

    /// The model ROUTES writes into the commission.
    ///
    /// Asks the PROVIDER (`list_models`) rather than naming one: a hardcoded
    /// model is a claim about someone else's catalogue that goes stale without
    /// a reader. `nil` when the provider does not answer a listing — v1's
    /// `list_models` is Ollama-only (`lib.rs:236` returns `Unsupported` for
    /// every other prefix), so a keyed provider legitimately yields nil and
    /// the arm above names that state instead of guessing a model.
    static func firstModel(for id: String,
                           core: ZeusCoreProtocol?,
                           key: String?,
                           baseURL: String?) -> String? {
        guard let core else { return nil }
        let probeKey = keylessProviders.contains(id) ? ollamaKeyPlaceholder : (key ?? "")
        guard let models = try? core.listModels(id: id, key: probeKey, baseUrl: baseURL) else {
            return nil
        }
        return models.first
    }
}
