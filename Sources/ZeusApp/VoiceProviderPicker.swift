import Foundation

/// THE VOICE PICKER'S MODEL — which providers can carry a realtime voice
/// session, and whether this phone already holds the key for each.
///
/// ## Why the filter is the core's dialect and not a Swift list
///
/// `realtime_dialect(id)` (bridge `lib.rs:1695`) is an exhaustive match with no
/// catch-all: a provider the core adds upstream fails to COMPILE there until
/// someone rules on its wire protocol. A Swift allowlist here would be a second
/// copy of that ruling with no compiler behind it. So the picker asks the core
/// per catalog row and shows exactly the rows whose answer is not `.none`.
///
/// ## Why the key is REUSED, never collected here
///
/// The text onboarding already stores the operator's key in the Keychain under
/// the provider id (`ProviderKeyStore`). A voice choice is the same provider
/// and the same secret; asking again would create two copies that can drift.
/// The picker reads PRESENCE only for rendering; the bytes leave the store in
/// exactly one place, `connect(for:...)`, on the way into `resolveRealtime`.
///
/// ## The two empty answers are different facts
///
/// - `.noRealtimeProvider`: the catalog has NO row that speaks a dialect. The
///   voice surface must say so instead of rendering a dead button.
/// - choices exist but none `hasKey`: the operator can fix it by adding a key.
/// Folding these into one "nothing to pick" would hide which one is true.
enum VoiceProviderState: Equatable {
    case noRealtimeProvider
    case choices([VoiceProviderChoice])
}

struct VoiceProviderChoice: Equatable {
    let id: String
    let label: String
    let dialect: RealtimeDialect
    /// A key for this provider id is already in the Keychain.
    let hasKey: Bool
}

/// The dialect lookup, injectable so tests own the mapping instead of
/// asserting on whatever the linked core carries today. `nil` = the core
/// refused the id (`realtime_dialect` THROWS on an unknown id; it never
/// answers `.none` for one).
typealias RealtimeDialectLookup = (String) -> RealtimeDialect?

enum VoiceProviderPicker {

    static let coreDialect: RealtimeDialectLookup = { id in
        try? realtimeDialect(id: id)
    }

    /// Catalog order is preserved — the picker holds no ordering of its own.
    static func state(catalog: ProviderCataloging,
                      keys: ProviderKeyStoring,
                      dialect: RealtimeDialectLookup = coreDialect) -> VoiceProviderState {
        let choices: [VoiceProviderChoice] = catalog.rows().compactMap { row in
            guard let d = dialect(row.id), d != .none else { return nil }
            return VoiceProviderChoice(id: row.id,
                                       label: row.label,
                                       dialect: d,
                                       hasKey: hasKey(row.id, in: keys))
        }
        return choices.isEmpty ? .noRealtimeProvider : .choices(choices)
    }

    /// Whitespace-only is not a key: `resolve_realtime` refuses an empty
    /// credential, so presence must not claim one the core will reject.
    private static func hasKey(_ id: String, in keys: ProviderKeyStoring) -> Bool {
        guard let k = keys.providerKey(for: id) else { return false }
        return !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum ConnectError: Error, Equatable {
        /// The choice has no key in the Keychain — send the operator to add one.
        case noKey(providerId: String)
    }

    /// The one place the key's bytes leave the store for voice. Everything
    /// about URL and auth shape is the core's (`resolveRealtime`); this only
    /// supplies the stored key.
    static func connect(for choice: VoiceProviderChoice,
                        keys: ProviderKeyStoring,
                        model: String,
                        baseURLOverride: String?) throws -> RealtimeConnect {
        guard let key = keys.providerKey(for: choice.id),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectError.noKey(providerId: choice.id)
        }
        return try resolveRealtime(providerId: choice.id,
                                   credential: key,
                                   model: model,
                                   baseUrlOverride: baseURLOverride)
    }
}
