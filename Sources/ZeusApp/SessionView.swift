import SwiftUI

/// One turn in the session transcript.
///
/// The prototype's message objects (:411-412, :455-465) carry three fields:
/// `role` ('user' | 'agent'), `text`, and an optional `streaming` flag set
/// only on the trailing agent message while tokens arrive.
///
/// `role` is an enum for the same reason `Tab` and `AgentState` are: the
/// prototype's two string literals are the whole set, and a third would have
/// to break a `switch` rather than silently fall through a ternary.
struct Message: Identifiable, Equatable {
    enum Role: String, CaseIterable { case user, agent }

    let id = UUID()
    let role: Role
    var text: String
    var streaming: Bool = false
}

/// SessionTab, :855-903.
///
/// Structure carried: header row (orb + SESSION-01 + status line + badge),
/// scrolling transcript with role-asymmetric bubbles, composer whose trailing
/// button swaps between send and mic on whether the input trims to empty.
struct SessionView: View {
    let messages: [Message]
    let statusLine: String
    let state: AgentState
    var onSend: (String) -> Void = { _ in }
    var onVoice: () -> Void = {}

    @State private var input: String = ""

    private var trimmed: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            composer
        }
    }

    // MARK: - Header (:868-878)

    private var header: some View {
        HStack(spacing: 10) {
            OrbGlyph(diameter: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("SESSION-01")
                    .font(Theme.display(11, .bold))
                    .tracking(2.64)                       // 0.24em at 11pt
                    .foregroundStyle(Theme.text)
                Text(statusLine)
                    .font(Theme.mono(8.5))
                    .tracking(0.85)                       // 0.1em at 8.5pt
                    .foregroundStyle(Theme.r(0.65))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Badge(text: state.badgeText, color: state.badgeColor)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - Transcript (:879-898)

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { m in
                        bubbleRow(m).id(m.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func bubbleRow(_ m: Message) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if m.role == .agent {
                OrbGlyph(diameter: 24).padding(.bottom, 2)
            }
            bubble(m)
            if m.role == .user { Color.clear.frame(width: 0) }
        }
        .frame(maxWidth: .infinity,
               alignment: m.role == .user ? .trailing : .leading)
    }

    /// The corner radii are asymmetric per role in the source
    /// (`12px 12px 3px 12px` for user, `12px 12px 12px 3px` for agent) — the
    /// tail sits on the speaker's side.
    @ViewBuilder
    private func bubble(_ m: Message) -> some View {
        let isUser = m.role == .user
        HStack(alignment: .bottom, spacing: 0) {
            Text(m.text)
                .font(Theme.body(14))
                .foregroundStyle(Theme.text)
            if m.streaming { StreamingCaret() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isUser ? Theme.r(0.08) : Theme.w(0.04))
        .overlay(
            BubbleShape(tailOnTrailing: isUser)
                .stroke(isUser ? Theme.r(0.25) : Theme.w(0.07),
                        lineWidth: Theme.hairline)
        )
        .clipShape(BubbleShape(tailOnTrailing: isUser))
        .frame(maxWidth: 300, alignment: isUser ? .trailing : .leading)
    }

    // MARK: - Composer (:900-914)

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("", text: $input, prompt:
                Text("Message ZEUS")
                    .foregroundStyle(Theme.w(0.3))
            )
            .font(Theme.body(14))
            .foregroundStyle(Theme.text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .frame(height: Theme.controlSize)
            .background(Theme.w(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .stroke(Theme.w(0.08), lineWidth: Theme.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
            .onSubmit(send)

            // The button IDENTITY changes with the input, not just its icon —
            // send and voice are different actions, so this is a branch and
            // not a conditional label.
            if trimmed.isEmpty {
                accentButton(symbol: "mic", label: "Comms", action: onVoice)
            } else {
                accentButton(symbol: "arrow.up", label: "Send", action: send)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func accentButton(symbol: String,
                              label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: Theme.controlSize, height: Theme.controlSize)
                .background(Theme.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
        }
        .accessibilityLabel(label)
    }

    private func send() {
        let t = trimmed
        guard !t.isEmpty else { return }
        onSend(t)
        input = ""
    }
}

/// The blinking token caret, :889-895 — 2.5pt wide, ACC2, 0.8s cycle.
private struct StreamingCaret: View {
    @State private var on = true

    var body: some View {
        Rectangle()
            .fill(Theme.accent2)
            .frame(width: 2.5, height: 12)
            .offset(y: 2)
            .padding(.leading, 2)
            .opacity(on ? 1 : 0)
            .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true),
                       value: on)
            .onAppear { on = false }
    }
}

/// Bubble with one squared corner on the speaker's side.
private struct BubbleShape: Shape {
    let tailOnTrailing: Bool
    private let big: CGFloat = 12
    private let small: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect,
             cornerRadii: RectangleCornerRadii(
                topLeading: big,
                bottomLeading: tailOnTrailing ? big : small,
                bottomTrailing: tailOnTrailing ? small : big,
                topTrailing: big))
    }
}

/// Placeholder for the prototype's canvas-drawn `DeviceOrb` (:38-296).
///
/// The real orb is ~260 lines of 2D canvas work — arcs whose count varies
/// with mode, a level-driven radius, per-frame rotation. NONE of that is
/// implemented here; this is a gradient disc standing in at the two call
/// sites the session view needs (34pt header, 24pt bubble avatar).
///
/// Stated at the site rather than in a note: anyone reading this file sees
/// the gap where they would otherwise assume the orb was ported.
struct OrbGlyph: View {
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Theme.accent2.opacity(0.9), Theme.accentDeep.opacity(0.5)],
                    center: .init(x: 0.35, y: 0.3),
                    startRadius: 0,
                    endRadius: diameter * 0.8
                )
            )
            .overlay(Circle().stroke(Theme.r(0.35), lineWidth: Theme.hairline))
            .frame(width: diameter, height: diameter)
    }
}
