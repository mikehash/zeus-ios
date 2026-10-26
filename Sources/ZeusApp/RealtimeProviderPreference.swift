import Foundation

/// WHICH PROVIDER CARRIES VOICE — the operator's pick from the voice picker.
///
/// ## Stores the provider id, never the key
///
/// The secret lives in the Keychain under the provider id (`ProviderKeyStore`);
/// this preference only names WHICH entry voice uses. `UserDefaults` is not a
/// secret store, so nothing but the id is ever written here.
///
/// ## A stale id reads as `nil`, never as a substitute
///
/// Like `VoicePreference` falling back to AUTO for an uninstalled voice, a
/// stored id counts only while it is still a choice in the CURRENT picker state
/// AND that choice has a key. Otherwise `resolved` is `nil` — the caller shows
/// the picker. Voice never picks a provider on its own: there is deliberately no
/// "first keyed choice" fallback, because silently routing the operator's
/// voice to a provider they did not choose is worse than asking.
enum RealtimeProviderPreference {
    static let key = "zeus.voice.realtimeProvider"

    static func storedID(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    /// `nil` clears the choice.
    static func set(_ id: String?, _ defaults: UserDefaults = .standard) {
        if let id { defaults.set(id, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// The stored pick, if it is still a keyed choice in `state`; else `nil`.
    static func resolved(in state: VoiceProviderState,
                         _ defaults: UserDefaults = .standard) -> VoiceProviderChoice? {
        guard let id = storedID(defaults),
              case let .choices(choices) = state,
              let hit = choices.first(where: { $0.id == id }),
              hit.hasKey
        else { return nil }
        return hit
    }
}
