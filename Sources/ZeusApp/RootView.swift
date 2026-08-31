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
    @State private var tab: Tab = .zeus
    @State private var agentState: AgentState = .ambient

    /// Seeded from the prototype's initial transcript, :411-412.
    @State private var messages: [Message] = [
        Message(role: .agent,
                text: "Operator link established. All systems nominal — Kitchen node quiet. Standing by.")
    ]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().overlay(Theme.r(0.25))
                TabBar(selection: $tab)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .zeus:
            PlaceholderPane(title: "ZEUS", detail: "agent")
        case .session:
            SessionView(
                messages: messages,
                // :661 — the status line is a function of link topology, which
                // this tree has no source for yet. Fixed at the LINKED arm;
                // the `remote` ternary is not ported.
                statusLine: "LINKED · KITCHEN NODE",
                state: agentState,
                onSend: send,
                // :660 — voice hands control back to the ZEUS tab, then runs
                // the query. The tab switch is the part that is real here.
                onVoice: { tab = .zeus }
            )
        case .nodes:
            PlaceholderPane(title: "NODES", detail: "fleet")
        }
    }
}

// MARK: - Actions

extension RootView {
    /// `sendChat`, :455-467.
    ///
    /// The prototype streams the reply token-by-token off a timer. NO
    /// TRANSPORT EXISTS in this tree — there is no gateway client, no socket,
    /// nothing to send to. This appends the user turn and moves the agent
    /// state to `.thinking`, and stops there deliberately rather than faking
    /// a canned reply: a stub that answers looks identical to one that works,
    /// and the empty transcript is the honest signal that the wire is missing.
    func send(_ text: String) {
        messages.append(Message(role: .user, text: text))
        agentState = .thinking
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

private struct PlaceholderPane: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(Theme.display(28))
                .tracking(Theme.displayTracking)
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(Theme.mono(11))
                .tracking(1.0)
                .foregroundStyle(Theme.w(0.5))
        }
    }
}
