import SwiftUI

/// WHAT EACH PICKER ROW SAYS AND DOES — pure, so it is testable without a
/// renderer. The view below only lays these out; every decision a reviewer
/// would want to check (badge wording, which tap does what, the empty copy)
/// lives here.
///
/// ## A row without a key is an ADD-KEY row, not a dead row
///
/// Tapping a keyless provider must not "pick" it: `connect(for:)` would throw
/// `.noKey` one screen later and the operator would see a failure for a choice
/// the screen accepted. It raises the add-key flow instead.
///
/// ## This screen never collects a key
///
/// The one key-write site is `RoutePicker` (census:
/// `testTheKeyWriterIsTheKeychainAndNotUserDefaults`). The add-key action is
/// RAISE-ONLY — it hands the provider id up, and whoever owns the key store
/// opens the existing flow. A `SecureField` here would be a second write site
/// that the census does not read.
enum VoiceProviderRowAction: Equatable {
    case pick(String)
    case addKey(String)
}

struct VoiceProviderRowModel: Equatable {
    let id: String
    let label: String
    let badge: String
    let hasKey: Bool
    let action: VoiceProviderRowAction
    let accessibilityHint: String
}

enum VoiceProviderPickerPresentation {

    static let keyBadge = "KEY STORED"
    static let noKeyBadge = "ADD KEY"

    /// `.noRealtimeProvider` is the one state with NO rows and its own copy;
    /// it never renders as an empty list (same pixels as "still loading").
    static let noRealtimeTitle = "NO VOICE PROVIDER"
    static let noRealtimeBody =
        "None of the configured providers offers a realtime voice API. Text chat still works."

    /// Choices exist but no key is stored for any of them — fixable, so the
    /// copy points at the fix instead of claiming voice is unavailable.
    static let noKeyHint = "Add a key to one of these providers to use voice."

    static func rows(_ state: VoiceProviderState) -> [VoiceProviderRowModel] {
        guard case let .choices(choices) = state else { return [] }
        return choices.map { c in
            VoiceProviderRowModel(
                id: c.id,
                label: c.label,
                badge: c.hasKey ? keyBadge : noKeyBadge,
                hasKey: c.hasKey,
                action: c.hasKey ? .pick(c.id) : .addKey(c.id),
                accessibilityHint: c.hasKey
                    ? "Uses the stored key for voice."
                    : "No key stored. Opens key entry for this provider.")
        }
    }

    /// Shown above the list only when every choice lacks a key.
    static func showsNoKeyHint(_ state: VoiceProviderState) -> Bool {
        guard case let .choices(choices) = state else { return false }
        return !choices.contains { $0.hasKey }
    }
}

/// The onboarding voice-provider picker.
///
/// Both closures are UN-DEFAULTED, for the reason `SettingsView` gives for
/// `onOpenRoutes`: a defaulted closure lets a future call site ship the row
/// dead.
struct VoiceProviderPickerView: View {

    let state: VoiceProviderState

    /// The id of the provider voice currently uses, if any — drawn as selected.
    var selectedId: String?

    let onPick: (String) -> Void

    /// RAISE-ONLY. See `VoiceProviderPickerPresentation` — this view never
    /// writes a key.
    let onAddKey: (String) -> Void

    var body: some View {
        switch state {
        case .noRealtimeProvider:
            emptyState
        case .choices:
            list
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "waveform.slash")
                .font(Theme.body(18))
                .foregroundStyle(Theme.w(0.35))
            Text(VoiceProviderPickerPresentation.noRealtimeTitle)
                .font(Theme.display(11, .bold))
                .tracking(Theme.displayTracking)
                .foregroundStyle(Theme.text)
            Text(VoiceProviderPickerPresentation.noRealtimeBody)
                .font(Theme.body(13))
                .foregroundStyle(Theme.w(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if VoiceProviderPickerPresentation.showsNoKeyHint(state) {
                Text(VoiceProviderPickerPresentation.noKeyHint)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.warn)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            let rows = VoiceProviderPickerPresentation.rows(state)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                rowView(row, last: i == rows.count - 1)
            }
        }
    }

    private func rowView(_ row: VoiceProviderRowModel, last: Bool) -> some View {
        Button {
            switch row.action {
            case let .pick(id): onPick(id)
            case let .addKey(id): onAddKey(id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedId == row.id ? "largecircle.fill.circle" : "circle")
                    .font(Theme.body(16))
                    .foregroundStyle(row.hasKey ? Theme.accent2 : Theme.w(0.25))
                Text(row.label)
                    .font(Theme.body(14.5))
                    .foregroundStyle(row.hasKey ? Theme.text : Theme.w(0.55))
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: row.hasKey ? "key.fill" : "plus.circle")
                    Text(row.badge)
                }
                .font(Theme.mono(9.5))
                .tracking(1.14)
                .foregroundStyle(row.hasKey ? Theme.ok : Theme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Theme.joined([row.label, row.badge]))
        .accessibilityHint(row.accessibilityHint)
        .accessibilityAddTraits(selectedId == row.id ? .isSelected : [])
        .overlay(alignment: .bottom) {
            if !last {
                Rectangle().fill(Theme.w(0.05)).frame(height: Theme.hairline)
            }
        }
    }
}
