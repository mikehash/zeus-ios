import Foundation
import Security

/// The ONE place in the app that turns an endpoint into a bearer.
///
/// ## Why this type exists and why the presence store did not grow a getter
///
/// Two credential sources exist as of ③c: the environment (`ZEUS_GATEWAY_TOKEN`,
/// carried on `GatewayConfig.Endpoint.token`) and the Keychain (written by the
/// editor's SAVE path). Before this seam, four sites built a `Bearer` header
/// and three of them read `endpoint.token` directly — so wiring the Keychain
/// into two of them would have shipped TWO PRECEDENCES IN ONE APP: chat and
/// preflight on `ENV → KEYCHAIN`, approvals and routes on `ENV` alone. An
/// operator with a saved token would get a working session and a 401 approvals
/// queue, with the LINK line saying `KEYCHAIN` while the queue said otherwise.
/// That is the worst diagnostic shape available, so the precedence lives here,
/// exactly once, and every consumer reads it.
///
/// ## The read-back contract is NOT broken — it moved
///
/// `GatewayTokenStoring` stays presence-only (`kSecReturnData = false`,
/// `GatewayTokenStore.swift:14-17`): nothing reads the value back out of the
/// PRESENCE store. This type owns its own `kSecReturnData = true` query against
/// the same service/account pair, so the type that may see bytes is a
/// credential provider and never the surface that renders presence. A getter on
/// `GatewayTokenStoring` would have made every presence caller a potential
/// secret reader; a separate reader keeps the blast radius at one type.
///
/// ## `Endpoint` never hands a live secret to a consumer
///
/// `Endpoint.token` has exactly TWO code-line readers after this cut: the
/// `.environment` arm below, and `GatewayConfig.summary` — which is
/// presence-only and named as such at its site. Consumers take a
/// `CredentialProviding`, never the endpoint's token.
protocol CredentialProviding: Sendable {
    /// The bearer to send to this endpoint, or nil if there is none.
    func credential(for endpoint: GatewayConfig.Endpoint) -> String?

    /// WHERE the credential came from — for the LINK provenance word only.
    /// Returns nil when there is no credential; never returns the secret.
    func source(for endpoint: GatewayConfig.Endpoint) -> CredentialSource?
}

/// The provenance word. A word, never the bytes.
enum CredentialSource: String, Equatable {
    case environment = "ENV"
    case keychain    = "KEYCHAIN"
}

/// Production provider: `ENV → KEYCHAIN`, stated once, here.
///
/// The environment WINS because it is the debugging override — an operator who
/// exports `ZEUS_GATEWAY_TOKEN` expects that token on the wire regardless of
/// what a previous launch saved, and the LINK line says `ENV` so the win is
/// visible rather than silent. This is the same precedence direction
/// `GatewayConfig.resolve` uses for the URL (`GatewayConfig.swift:88-92`);
/// having the URL and the token disagree about which source outranks which
/// would be a trap with no surface to explain it.
struct KeychainCredentialProvider: CredentialProviding {

    /// Same service string as the presence store — one Keychain item, two
    /// readers with different `kSecReturnData`. Read from the store type so a
    /// rename cannot leave this reader querying a service nobody writes.
    private let service: String

    init(service: String = GatewayTokenStore.service) {
        self.service = service
    }

    func credential(for endpoint: GatewayConfig.Endpoint) -> String? {
        if let env = endpoint.token { return env }
        guard let host = endpoint.url.host, !host.isEmpty else { return nil }
        return keychainToken(host: host)
    }

    func source(for endpoint: GatewayConfig.Endpoint) -> CredentialSource? {
        if endpoint.token != nil { return .environment }
        guard let host = endpoint.url.host, !host.isEmpty,
              keychainToken(host: host) != nil else { return nil }
        return .keychain
    }

    /// The ONLY `kSecReturnData = true` read in the app.
    private func keychainToken(host: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        // Anything but a clean hit is treated as ABSENT — a credential the
        // Keychain cannot vouch for is not one the app may claim, the same
        // rule the presence store states at `GatewayTokenStore.swift`.
        guard status == errSecSuccess,
              let data = out as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }
}

/// Test/preview provider. Same precedence, no Keychain — so a leg that asserts
/// the ORDER is asserting this type's order and the production type's order is
/// asserted by the shared-shape leg, not by inference.
struct StubCredentialProvider: CredentialProviding {
    /// Keyed by host, standing in for the Keychain half.
    var stored: [String: String] = [:]

    func credential(for endpoint: GatewayConfig.Endpoint) -> String? {
        if let env = endpoint.token { return env }
        guard let host = endpoint.url.host else { return nil }
        return stored[host]
    }

    func source(for endpoint: GatewayConfig.Endpoint) -> CredentialSource? {
        if endpoint.token != nil { return .environment }
        guard let host = endpoint.url.host, stored[host] != nil else { return nil }
        return .keychain
    }
}
