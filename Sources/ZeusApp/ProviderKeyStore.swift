import Foundation
import Security

/// Keychain home for PROVIDER keys — the operator's Anthropic/OpenAI/… secret.
///
/// ## Why this is not a method on `CredentialProviding`
///
/// `CredentialProviding` is `Sendable` with two VALUE-TYPE conformers
/// (`KeychainCredentialProvider`, `StubCredentialProvider`), and every
/// consumer holds it as a non-mutable `let` across six injection sites. A
/// writer there would have to be `mutating` (uncallable through those `let`s)
/// or force both conformers to reference types, dragging `Sendable`
/// conformance across 23 param-typed lines to gain a writer exactly ONE
/// surface calls. The app already keeps its write side in a class-bound
/// protocol one file over — `GatewayTokenStoring: AnyObject` with a Keychain
/// conformer and an in-memory twin on `LaunchArgs.useInMemoryTokens`. This is
/// that recipe, one key space over, so `CredentialProviding` keeps one job
/// (endpoint → bearer) and its value semantics.
///
/// ## Why the account is the PROVIDER ID and there is no host
///
/// `GatewayTokenStore` keys on the gateway's HOST because a gateway token is
/// a property of the endpoint you are talking to. A provider key is a
/// property of the PROVIDER and travels with it: the same Anthropic key is
/// the same secret whether the core runs on this phone or behind a gateway
/// on the LAN. Keying it by host would store one secret per endpoint and
/// re-ask the operator for a key they already gave. Separate service string,
/// separate key space, no collision with the token store.
///
/// ## The value comes back OUT of this store, unlike the token store
///
/// `GatewayTokenStoring` is deliberately presence-only (`kSecReturnData`
/// absent) because nothing in the app needs the token's bytes — the request
/// path reads it through `CredentialProviding`. A provider key IS needed as
/// bytes, by `CoreArming.arm(providerKey:)`, so this store reads data back.
/// That is the whole reason it is a distinct protocol rather than a third
/// method on the token store: adding a getter there would make every
/// presence caller a potential secret reader.
protocol ProviderKeyStoring: AnyObject {
    func providerKey(for id: String) -> String?
    func setProviderKey(_ key: String, for id: String)
    func removeProviderKey(for id: String)
}

final class ProviderKeyStore: ProviderKeyStoring {

    /// Versioned and distinct from `GatewayTokenStore.service`: two key
    /// spaces, no bleed, and a schema change can bump one without the other.
    static let service = "com.zeus.provider-key.v1"

    private let service: String

    init(service: String = ProviderKeyStore.service) {
        self.service = service
    }

    private func query(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
    }

    func providerKey(for id: String) -> String? {
        var item = query(id: id)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        // A stored blob that is not UTF-8 is not a key this app wrote; it is
        // treated as absent rather than force-decoded into a broken string
        // that would arm the core with garbage.
        return String(data: data, encoding: .utf8)
    }

    func setProviderKey(_ key: String, for id: String) {
        var item = query(id: id)
        let update: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
        ]
        // UPDATE-FIRST, same reason as the token store: an Add onto an
        // existing item is `errSecDuplicateItem`, so re-entering a key for
        // the same provider must REPLACE rather than fail.
        var status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            item.merge(update) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        _ = status
    }

    func removeProviderKey(for id: String) {
        _ = SecItemDelete(query(id: id) as CFDictionary)
    }
}

/// In-memory stand-in, on the same launch switch as `InMemoryTokenStore`.
///
/// Every leg below runs against THIS: a test that exercised the real
/// Keychain would be asserting on whatever the host Mac happens to hold, and
/// on a simulator the Keychain persists across runs, so a "two ids, two
/// keys" leg would pass on residue from an earlier run.
final class InMemoryProviderKeyStore: ProviderKeyStoring {
    private var keys: [String: String] = [:]

    func providerKey(for id: String) -> String? { keys[id] }
    func setProviderKey(_ key: String, for id: String) { keys[id] = key }
    func removeProviderKey(for id: String) { keys[id] = nil }
}
