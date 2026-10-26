import Foundation

/// THE TWO VOICE-PROVIDER SHEETS, AS ONE VALUE.
///
/// `RootView` owns this as a single `@State`. The picker and the key-only
/// sheet are never open together: ADD KEY closes the picker and opens the
/// key sheet for that provider in one mutation, so there is no frame in which
/// both claim the screen and no second flag that could disagree with the first.
///
/// Every transition is a plain function so the tests can drive the flow
/// without rendering anything. The view only binds to it.
struct VoiceProviderSheets: Equatable {

    /// The picker (`VoiceProviderPickerView`) is up.
    private(set) var pickerOpen = false

    /// The key-only sheet is up, for this provider. `nil` = closed.
    private(set) var keyOnlyProvider: String? = nil

    /// Bindable form of `pickerOpen`, for `SheetLayer`'s scrim dismissal.
    /// Setting `true` from outside is refused — opening goes through `open()`.
    var pickerPresented: Bool {
        get { pickerOpen }
        set { if !newValue { pickerOpen = false } }
    }

    /// Bindable form of `keyOnlyProvider != nil`. The scrim can only close it.
    var keyOnlyPresented: Bool {
        get { keyOnlyProvider != nil }
        set { if !newValue { keyOnlyProvider = nil } }
    }

    /// Settings' "Voice provider" row.
    mutating func open() {
        keyOnlyProvider = nil
        pickerOpen = true
    }

    /// A keyed row was tapped. Stores the id — never the key — and closes.
    mutating func pick(_ id: String, _ defaults: UserDefaults = .standard) {
        RealtimeProviderPreference.set(id, defaults)
        pickerOpen = false
    }

    /// An ADD KEY row was tapped. Close the picker, open key entry for `id`.
    /// Writes nothing: the key-only sheet is the one place this flow stores a
    /// key, through `RoutePicker.storeKey`.
    mutating func addKey(_ id: String) {
        pickerOpen = false
        keyOnlyProvider = id
    }

    /// The key-only sheet stored a key. Back to the picker so the operator
    /// picks — the provider is NOT chosen for them. Voice never auto-picks.
    mutating func keySaved(_ id: String) {
        keyOnlyProvider = nil
        pickerOpen = true
    }

    /// The Settings row's value. Reads only the stored id and the state; never
    /// a key's text.
    static func settingsValue(_ state: VoiceProviderState,
                              _ defaults: UserDefaults = .standard) -> String {
        if case .noRealtimeProvider = state { return "UNAVAILABLE" }
        guard let hit = RealtimeProviderPreference.resolved(in: state, defaults) else {
            return "NOT SET"
        }
        return hit.label.uppercased()
    }
}
