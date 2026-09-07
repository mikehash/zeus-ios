import SwiftUI

/// The bottom-sheet layer.
///
/// Transcribed from `prototypes/ZeusApp.jsx:754-812` at `4798cc2` — the
/// scrim + panel pair that both the route sheet (`:756`) and the revoke
/// confirm (`:799`) render through.
///
/// ── WHY A CONTAINER AND NOT TWO `.sheet` MODIFIERS ──────────────────────
/// Before this file, `grep -rlE '\.sheet\(|confirmationDialog|\.alert\(' Sources`
/// returned **0 files**: the app had no modal layer at all. So C12 and C13 are
/// not "two rows sharing a mechanism" — they are the first two consumers of a
/// layer that did not exist. The prototype's sheet is not a system sheet: it is
/// a 16pt-radius panel inset 10pt from the edges, 12pt off the bottom, over a
/// 75% black scrim, in `Theme.surface` with an `r(0.3)` hairline. A system
/// `.sheet` renders a grabber, a system background and a system corner radius
/// — three visual disagreements with the SoT, on the surface the operator sees
/// first. This draws the prototype's shape instead.
struct SheetLayer<Content: View>: View {

    @Binding var isPresented: Bool
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .bottom) {
            // :759-763 — the scrim. Tapping it dismisses, which is the only
            // dismissal affordance the route sheet has besides its CLOSE row.
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
                // The scrim is a dismiss control with no label of its own, so
                // it needs one here or VoiceOver reads an unlabelled tap area.
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Dismiss")

            VStack(spacing: 0) {
                Text(title)
                    .font(Theme.display(12, .bold))
                    .tracking(2.9)
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(Theme.mono(8.5))
                    .tracking(0.85)
                    .foregroundStyle(Theme.w(0.35))
                    .padding(.top, 6)
                    .padding(.bottom, 12)

                content()
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            // FLOOR, not a ceiling. The prototype pins `maxHeight: 560`; every
            // child here is text, and text grows with Dynamic Type. A max
            // would clip the route list at AX5 — the same ruling as
            // `HomeView:200`. The scroll view inside handles overflow.
            .frame(maxHeight: 560, alignment: .bottom)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.r(0.3), lineWidth: Theme.hairline)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .transition(.opacity)
    }
}

/// One row in the route sheet. `:771-783`.
struct RouteRow: View {

    let route: Route
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(selected ? Theme.accent : Theme.w(0.25))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.name)
                        .font(Theme.display(10.5, .bold))
                        .tracking(1.6)
                        .foregroundStyle(selected ? Theme.text : Theme.w(0.7))
                    // `reach`, not the prototype's `meta` — see `Route.swift`.
                    // A topology, which is true by identity; not a latency,
                    // which would be a number nothing measured.
                    Text(route.reach.rawValue)
                        .font(Theme.mono(8))
                        .tracking(0.8)
                        .foregroundStyle(Theme.w(0.32))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Floor: the row holds two scaling labels.
            .frame(minHeight: Theme.controlSize)
            .background(selected ? Theme.r(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Theme.r(0.4) : Color.clear,
                            lineWidth: Theme.hairline)
            )
        }
        .buttonStyle(.plain)
        // The selected route is drawn with a filled dot and a tinted
        // background — both invisible to VoiceOver. Without this trait the
        // selection is unrecoverable from the accessibility tree.
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
