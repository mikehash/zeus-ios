import Foundation

/// Durable home for the value commissioning produces.
///
/// WHY THIS EXISTS
/// ---------------
/// `Commission` was `@State` on `ZeusApp`, which means it lived exactly as
/// long as the process. An operator completed the flow, the app was killed by
/// the system or by a swipe-up, and the next launch showed the splash again
/// with no indication that anything had been lost. That is not a missing
/// feature — the flow *ran*, produced a value, and the value was discarded —
/// so it reads to the operator as the app forgetting them.
///
/// WHAT IS AND IS NOT STORED HERE
/// ------------------------------
/// `Commission` carries the route *mode* (`managed` / `byok`), the callsign,
/// and whether a node was enrolled. It carries **no credential**: the BYOK key
/// and the gateway token live in `GatewayConfig`'s environment source, and
/// nothing on this path ever sees them. That is what makes `UserDefaults`
/// the correct store rather than the Keychain — Keychain is for secrets, and
/// putting non-secrets there buys no security while adding a failure mode
/// (items surviving app deletion, `errSecInteractionNotAllowed` before first
/// unlock) that a preference does not have.
///
/// If a credential is ever added to `Commission`, this comment is the place
/// that must change first: the store becomes Keychain-backed and the
/// `Codable` blob stops being appropriate.
protocol CommissionStoring: AnyObject {
    /// The persisted commission, or `nil` if none was ever written.
    ///
    /// Returns `nil` — never a default-constructed `Commission` — because an
    /// absent commission and an empty one mean different things: the first
    /// says "run the flow", the second says "the flow ran and produced
    /// nothing". Collapsing them would silently skip commissioning for an
    /// operator who never did it.
    func load() -> Commission?

    /// Persist, replacing any previous value.
    func save(_ commission: Commission)

    /// Forget the commission. Used by decommissioning and by tests.
    func clear()
}

// `Commission: Codable` is declared in `Commissioning.swift`, not here.
// Swift only synthesises `init(from:)` / `encode(to:)` in the file that
// declares the type — an extension in this file compiles to two errors that
// name synthesis rather than file scope, so the conformance lives next to the
// struct and this store consumes it.

// MARK: - UserDefaults implementation

/// `UserDefaults`-backed store.
///
/// The suite is injected rather than defaulted to `.standard` at the point of
/// use, because a test writing to `.standard` mutates the simulator's real
/// preference domain and leaks into every subsequent test in the process —
/// the same reasoning that keeps `GatewayConfig.resolve(from:)` taking its
/// environment as a parameter.
final class UserDefaultsCommissionStore: CommissionStoring {
    /// The key is versioned. A future `Commission` that cannot be decoded
    /// from this shape gets a new key rather than a migration, so an old
    /// build and a new build on the same device cannot corrupt each other.
    static let key = "com.zeus.commission.v1"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = UserDefaultsCommissionStore.key) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> Commission? {
        guard let data = defaults.data(forKey: key) else { return nil }
        // A decode failure is treated as "no commission", not as a crash and
        // not as a default value. The stored blob is from an older or
        // corrupted shape; the honest response is to run the flow again,
        // which is exactly what `nil` produces.
        guard let commission = try? JSONDecoder().decode(Commission.self, from: data) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return commission
    }

    func save(_ commission: Commission) {
        // An encode failure here is unreachable for this shape (two strings
        // and a bool), but it is not *asserted* unreachable: swallowing it
        // leaves the previous value in place, which is strictly better than
        // trapping in a release build during the last step of onboarding.
        guard let data = try? JSONEncoder().encode(commission) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// In-memory store. Used by tests and by the DEBUG launch-argument seam, so a
/// screenshot run cannot write into the simulator's preference domain and
/// change what a *later* unargumented launch photographs.
final class InMemoryCommissionStore: CommissionStoring {
    private var value: Commission?

    init(seed: Commission? = nil) { self.value = seed }

    func load() -> Commission? { value }
    func save(_ commission: Commission) { value = commission }
    func clear() { value = nil }
}
