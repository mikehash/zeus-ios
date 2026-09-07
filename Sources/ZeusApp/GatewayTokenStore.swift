import Foundation
import Security

/// Keychain home for the gateway token — the ONE credential G0 persists.
///
/// WHY KEYCHAIN AND NOT THE COMMISSION BLOB: `Commission` rides in
/// `UserDefaults` precisely because it carries no secret
/// (`CommissionStore.swift` docstring). The token is a secret, so it lives
/// here, as a generic password keyed by the URL's host — which means one
/// token per host, and switching hosts switches credentials rather than
/// replaying one token at every gateway the operator ever typed.
///
/// The SERVICE string is fixed and versioned; the ACCOUNT is the host. A
/// `kSecReturnData`-less read answers presence; nothing in the app ever
/// reads the value back OUT of the store — the producer statement's
/// read-back contract for the token is a BOOLEAN, and this is the surface
/// that keeps it one.
protocol GatewayTokenStoring: AnyObject {
    func hasToken(host: String) -> Bool
    func save(token: String, host: String)
    func removeToken(host: String)
}

final class GatewayTokenStore: GatewayTokenStoring {

    static let service = "com.zeus.gateway-token.v1"

    private let service: String

    init(service: String = GatewayTokenStore.service) {
        self.service = service
    }

    private func query(host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
    }

    func hasToken(host: String) -> Bool {
        var item = query(host: host)
        item[kSecReturnData as String] = false
        // `errSecItemNotFound` and "present" are the only two answers that
        // matter; any other status is treated as absent because a token the
        // store cannot vouch for is not a token the app can claim.
        let status = SecItemCopyMatching(item as CFDictionary, nil)
        return status == errSecSuccess
    }

    func save(token: String, host: String) {
        var item = query(host: host)
        let update: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
        ]
        // UPDATE-FIRST: an Add onto an existing item is `errSecDuplicateItem`,
        // so the write is upsert — the operator re-entering a token for the
        // same host must REPLACE, not fail.
        var status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            item.merge(update) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        _ = status
    }

    func removeToken(host: String) {
        _ = SecItemDelete(query(host: host) as CFDictionary)
    }
}

/// In-memory stand-in, for legs that must not touch a real (or simulated)
/// Keychain. Same protocol, same semantics, zero persistence.
final class InMemoryTokenStore: GatewayTokenStoring {
    private var tokens: [String: String] = [:]

    func hasToken(host: String) -> Bool { tokens[host] != nil }
    func save(token: String, host: String) { tokens[host] = token }
    func removeToken(host: String) { tokens[host] = nil }
}
