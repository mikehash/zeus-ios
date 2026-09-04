import SwiftUI

/// The three tabs the prototype declares at ZeusApp.jsx:835-837.
///
/// Exhaustive over the source: `grep -nE "label: *'"` returns exactly three
/// lines at that ref, so this enum is the whole set and not a prefix of it.
/// Being an enum rather than an array means a fourth tab cannot be added
/// without every `switch` over it failing to compile.
enum Tab: String, CaseIterable, Identifiable {
    case zeus
    case session
    case nodes

    var id: String { rawValue }

    /// Uppercased in the prototype's data, not by the view.
    var label: String {
        switch self {
        case .zeus:    return "ZEUS"
        case .session: return "SESSION"
        case .nodes:   return "NODES"
        }
    }

    /// SF Symbol standing in for the prototype's lucide-react glyph.
    /// House / MessageCircle / Cpu at :835-837 respectively.
    var symbol: String {
        switch self {
        case .zeus:    return "house"
        case .session: return "message"
        case .nodes:   return "cpu"
        }
    }
}

struct RootView: View {
    @State private var tab: Tab = LaunchArgs.initialTab

    /// :433 — `showToast(text)` sets, then clears after 2800ms.
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    /// The session loop. RootView READS the transcript and calls `send`; it
    /// cannot append a message or set an agent state, because neither is
    /// writable from here. The seed lives in the engine's initialiser.
    // No transport argument. The engine's DEFAULT factory resolves config and
    // builds a transport per turn, handing it the engine-owned session id — so
    // there is no production call site here to drift out of step with the
    // seam. A call site that does not exist cannot be forgotten during an edit.
    @StateObject private var session = SessionEngine()

    /// Link state, MEASURED — the source `statusLine` did not have. The
    /// monitor resolves config once at construction and polls `/health`; both
    /// consuming sites read its verdict rather than a literal.
    @StateObject private var link = LinkMonitor()

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().overlay(Theme.r(0.25))
                TabBar(selection: $tab)
            }

            // :511-520 — the toast, top-anchored at 54pt. The prototype
            // dismisses on a 2800ms timer (`showToast`, :433); same duration
            // here, driven by a task rather than a scheduler handle.
            if let toast {
                ToastBanner(text: toast)
                    .padding(.top, 54)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(70)
            }
        }
        .animation(.easeOut(duration: 0.22), value: toast)
        .preferredColorScheme(.dark)
        // `start()` is idempotent by design: `.task` re-fires on view identity
        // changes, and two poll loops would halve the effective interval with
        // nothing in the UI to show it.
        .task { link.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .zeus:
            // NOT a placeholder any more. `LaunchArgs.initialTab` returns
            // `.zeus` unconditionally in release, so this is the cold-start
            // destination for every commissioned operator on every launch —
            // which is why it ships with restore rather than behind it.
            HomeView(link: link, session: session, onOpenSession: { tab = .session })
        case .session:
            SessionView(
                messages: session.messages,
                // :661 — the status line is a function of link topology.
                // It WAS the literal "LINKED · KITCHEN NODE", which read
                // LINKED with no gateway configured, none reachable, and none
                // answering. It is now the probe's verdict; the `remote`
                // ternary the prototype had is subsumed by `LinkState`.
                statusLine: link.state.statusLine,
                state: session.state,
                onSend: session.send,
                // :660 — voice hands control back to the ZEUS tab, then runs
                // the query. The tab switch is the part that is real here.
                onVoice: { tab = .zeus }
            )
        case .nodes:
            NodesView(link: link.state, onToast: showToast)
        }
    }
}

// MARK: - Actions

extension RootView {
    /// `sendChat`, :455-467 — now owned by `SessionEngine`.
    ///
    /// The prototype streams a HARDCODED reply off a `setTimeout` ladder. The
    /// turn lifecycle here is real — user turn, thinking, deltas folded into a
    /// trailing agent message, caret cleared on every exit — and the only
    /// missing piece is the sender. `UnconfiguredTransport` fails loudly with
    /// `NO TRANSPORT` rather than answering, because a stub that answers is
    /// indistinguishable from a wired build and the first demo would believe
    /// the wire exists.
    ///
    /// RootView has NO transcript-mutating method any more. The previous
    /// `send` appended to `@State messages` from the view layer; a second
    /// writer added beside it would have been a compile-clean defect. There
    /// is now nothing here to write to.

    /// :433 — one live toast at a time; a second call replaces the first and
    /// cancels its dismissal, so the earlier timer cannot clear the later
    /// message. The prototype's `later()` has the same effect by overwriting
    /// state; here the cancel is explicit because a Task outlives the value.
    private func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task {
            try? await Task.sleep(for: .milliseconds(2800))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

/// :514-519 — accent-bordered pill on a near-opaque surface.
private struct ToastBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
            Text(text)
                .font(Theme.mono(9.5))
                .tracking(1.14)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.r(0.4), lineWidth: Theme.hairline)
        )
        .padding(.horizontal, 24)
    }
}

private struct TabBar: View {
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { t in
                let active = t == selection
                Button {
                    selection = t
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.symbol)
                            .font(.system(size: 17, weight: .medium))
                        Text(t.label)
                            .font(Theme.display(9))
                            .tracking(Theme.displayTracking)
                    }
                    .foregroundStyle(active ? Theme.accent2 : Theme.w(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.label)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .background(Theme.surface)
    }
}
