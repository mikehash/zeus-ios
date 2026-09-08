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
    /// The gateway-named session id, or `nil` before the first reply names
    /// one. Not defaulted to a string: a default here would reintroduce the
    /// exact defect this field removes.
    var sessionID: String? = nil
    /// Deep-link prefill, consumed once.
    ///
    /// A BINDING and not a plain value, because the view must be able to
    /// clear it: `zeus://session?prompt=x` twice in a row is two distinct
    /// user intents, and a non-clearing value would compare equal the second
    /// time and silently do nothing. The owner sets it; this view nils it
    /// the moment it has been applied.
    ///
    /// Declared ABOVE the closures deliberately: Swift's memberwise init
    /// fixes argument order to declaration order, and the call site reads
    /// `prefill:` before `onSend:`.
    var prefill: Binding<String?> = .constant(nil)

    /// NO DEFAULT. `= { _ in }` here would ship a composer that renders,
    /// accepts text, highlights SEND, takes the tap and does nothing — an
    /// empty closure is worse than an absent one because it is a lie with a
    /// tap target, indistinguishable from working software until an operator
    /// tries it. `prefill` above keeps its default for the opposite reason: a
    /// binding to nothing is a VALUE, not an unwired affordance.
    var onSend: (String) -> Void

    /// What the voice affordance is doing right now.
    ///
    /// A VALUE, not a flag the view derives: the four states are decided by
    /// OS capability and two authorization grants, none of which a `View`
    /// body can read. Owned above, rendered here.
    var voiceState: VoiceState = .idle

    /// Tapping the mic. Toggles — the same button starts and stops.
    var onVoice: () -> Void = {}

    /// Why sending is impossible right now, or `nil` if it is possible.
    ///
    /// A STRING rather than a Bool, because a disarmed composer with no reason
    /// is a dead button: the operator sees that it does not work and has no way
    /// to learn why. The value is `GatewayConfig.disarmReason` — today only
    /// `.local(.noProvider)` produces one.
    ///
    /// Rendered BEFORE the first send. The bridge would also refuse the turn
    /// (`BridgeError::NoProvider`), but discovering a configuration fact as a
    /// failed message in the transcript teaches the operator that the app is
    /// broken rather than that the setup is unfinished.
    /// NO DEFAULT, for the reason stated at `headerAccessibilityLabel`, one
    /// level up: a memberwise default lets the next call site omit readiness
    /// and silently render a live composer over an unarmed core. The sole
    /// production caller (`RootView:399`) passes it today; the `= nil` was a
    /// hole waiting for a second caller, not a convenience anyone used.
    var disarmReason: String?

    // DECLARED LAST, and that is load-bearing: Swift's memberwise init fixes
    // argument order to declaration order, so this property's position in the
    // file IS the position of `disarmReason:` at the call site.


    @State private var input: String = ""

    private var trimmed: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The header identifier, derived — never a literal.
    ///
    /// Three states, and the middle one is the point: before any turn the
    /// gateway has named nothing, so there IS no session id, and the honest
    /// render is an absence. A placeholder number would have the shape of
    /// data. Truncated to the first 8 characters because gateway ids are
    /// UUID-length and the row is 11pt tracked at 0.24em — the full value
    /// would push the status line out of the row.
    static func sessionTitle(for id: String?) -> String {
        guard let id, !id.isEmpty else { return Theme.joined(["SESSION", "—"]) }
        return Theme.joined(["SESSION", id.prefix(8).uppercased()])
    }

    /// Whether a send can proceed. THE predicate, used by both the button's
    /// `enabled:` and by `send()` — two call sites, one decision.
    ///
    /// `static` and pure for the reason `sessionTitle` is: a SwiftUI body is
    /// not observable in-process (this target has no ViewInspector), so a
    /// predicate left inline in the view is guardable only by screenshot.
    ///
    /// 🔴 APERTURE, stated because the guard is narrower than it looks: this
    /// function is tested; the two lines that CALL it are not. A mutation that
    /// replaces `enabled: SessionView.canSend(...)` with `enabled: true`
    /// survives the whole suite — measured, not feared (MUT-3 at this commit).
    /// One decision in one testable place is a smaller unguarded surface than
    /// two inline expressions, not a closed one.
    static func canSend(trimmedInput: String, disarmReason: String?) -> Bool {
        disarmReason == nil && !trimmedInput.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            // The state SAID, above the composer, not merely glyphed. A
            // slashed icon tells an operator something is off; this tells
            // them WHICH thing and whether Settings can fix it. `.idle`
            // renders nothing at all — a persistent "ready" line would be
            // status chrome for a state that is just the absence of one.
            if let line = voiceState.line {
                Text(line)
                    .font(Theme.mono(10))
                    .tracking(1.2)
                    .foregroundStyle(voiceState == .listening
                                     ? Theme.accent : Theme.w(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .accessibilityLabel(line)
            }
            // SAID, not merely enforced. The same row the voice states use,
            // for the same reason: a disabled control tells the operator that
            // something is off, and only text tells them which thing and what
            // to do about it. `NO PROVIDER — SET ONE IN ROUTES` names the
            // destination, so the sentence is an instruction rather than a
            // diagnosis.
            if let reason = disarmReason {
                Text(reason)
                    .font(Theme.mono(10))
                    .tracking(1.2)
                    .foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .accessibilityLabel(reason)
            }
            composer
        }
        // Apply on APPEAR as well as on change: a deep link arriving on a
        // cold start sets the value before this view exists, so an
        // `onChange`-only wiring would drop the very first link the app ever
        // receives — the one case a user is most likely to try.
        .onAppear { applyPrefill() }
        .onChange(of: prefill.wrappedValue) { _, _ in applyPrefill() }
    }

    /// Move a pending prefill into the composer, then clear it.
    ///
    /// REPLACES rather than appends. A deep link is a fresh intent, not a
    /// continuation of half-typed text; appending would splice a URL's words
    /// onto a sentence the user was mid-way through and send the result on
    /// one tap.
    ///
    /// The clear is what makes the binding single-shot — see `prefill`.
    private func applyPrefill() {
        guard let pending = prefill.wrappedValue, !pending.isEmpty else { return }
        input = pending
        prefill.wrappedValue = nil

        // CAPTURE SEAM, `#if DEBUG` and inert unless `-zeusAutoSend` is passed.
        // Calls `send` — the SAME function the SEND button's `action:` calls —
        // so `canSend`'s refusal of a disarmed composer applies here
        // identically. A seam that assembled its own turn would be measuring
        // itself rather than the production path. Single-shot by inheritance:
        // `prefill` is nilled above, so this fires once per deep link and not
        // on the re-render that follows.
        #if DEBUG
        if LaunchArgs.autoSend { send() }
        #endif
    }

    // MARK: - Header (:868-878)

    private var header: some View {
        HStack(spacing: 10) {
            OrbGlyph(diameter: 34, mode: state.orbMode)

            VStack(alignment: .leading, spacing: 2) {
                Text(SessionView.sessionTitle(for: sessionID))
                    .font(Theme.display(11, .bold))
                    .tracking(2.64)                       // 0.24em at 11pt
                    .foregroundStyle(Theme.text)
                Text(statusLine)
                    .font(Theme.mono(8.5))
                    .tracking(0.85)                       // 0.1em at 8.5pt
                    .foregroundStyle(Theme.r(0.65))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The pill reads the readiness-composed pair, same derivation as
            // the home AGENT tile. `disarmReason` is already in scope here and
            // is the value the composer below gates on.
            Badge(text: headerBadge.text, color: headerBadge.tint)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
        // ONE element, not four. Unmerged, VoiceOver reads the orb, the title,
        // the status line and the badge as separate stops — four swipes to
        // learn one thing. `.combine` concatenates the children's labels in
        // layout order, which is why the value below is applied to the group
        // and not to any child.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SessionView.headerAccessibilityLabel(
            sessionID: sessionID, status: statusLine, state: state,
            disarmReason: disarmReason))
    }

    /// The whole header as one spoken string.
    ///
    /// PHASE IS RECOVERABLE FROM THIS WHEN ARMED, AND DELIBERATELY NOT WHEN
    /// UNARMED. `state.badgeText` is four distinct strings over the four
    /// `AgentState` cases, so an armed label differs across every state — that
    /// difference is what makes "reads the engine phase" measurable rather than
    /// aspirational, and it is asserted directly rather than described here.
    /// Unarmed, all four collapse onto ONE PROSE SENTENCE (not `UNARMED` — the
    /// spoken arm is words, see `unarmedSpokenLabel`): the phase is not wrong, it is
    /// not answering the question, and announcing "reasoning" over a core with
    /// no route to a model is the spoken form of the green-pill lie. The
    /// injectivity leg is therefore TWO-ARMED — armed count ==
    /// `AgentState.allCases.count`, unarmed EQUAL to the literal for each of
    /// the four phases — with the arms asserted unequal so neither can pass on
    /// a constant. Count-1 alone is not enough: a function returning `""` has
    /// count 1 and says nothing, so the unarmed arm asserts the STRING.
    ///
    /// The badge and the status line are both carried because they answer
    /// different questions: phase (what the agent is doing) and topology (can
    /// we reach the gateway). Collapsing them would be the four-state link
    /// probe folding down to two, one surface over — `NOMINAL` beside
    /// `UNREACHABLE` is not a contradiction, it is two facts.
    ///
    /// The orb contributes nothing: it is `.accessibilityHidden(true)` at its
    /// call site, so `.combine` skips it. That is deliberate — the orb renders
    /// the same energy the badge names, and announcing both would say one
    /// thing twice.
    ///
    /// `disarmReason` is REQUIRED, not defaulted. A default would let a call
    /// site omit it and silently announce a phase over an unarmed core — the
    /// exact defect this parameter exists to close, reintroduced by omission.
    /// Four of the five callers are tests, and the fifth is the render at
    /// `:219`; making them all state the readiness is the point.
    /// The spoken payload when the core is unarmed. ZM's words, verbatim.
    ///
    /// NOT the pill's `UNARMED`, and not a composition of the caps strings:
    /// this is prose because it is spoken, and it carries the repair because
    /// the label is the screen-reader operator's ONLY channel to this screen.
    /// The general rule — a slot that cannot act must not name a repair — has
    /// its exception exactly here: this slot IS the operator's channel, so
    /// withholding the repair would leave them with a state and no route out
    /// of it. The visual pill withholds it because the screen around it says
    /// it in a slot that can act.
    ///
    /// It REPLACES the composition rather than appending to it. Title and
    /// status are answers to questions that presuppose an armed core; reading
    /// "SESSION ABC12345, LINKED, agent unarmed" spends two clauses on
    /// topology before reaching the one fact that matters. The visual header
    /// keeps them because the eye takes a pill in parallel with the text; a
    /// voice is serial and pays for every word.
    ///
    /// THE COST, AND ITS TRIGGER — recorded so the next author inherits the
    /// condition rather than the conclusion. Replacing the composition drops
    /// the session id from the spoken label. That is free TODAY because this
    /// screen shows one session and there is nothing to disambiguate it from.
    /// The moment a build puts two or more sessions in one navigable list,
    /// the unarmed labels of all of them are identical by ear — four phases
    /// times N sessions collapsing onto one sentence — and the suffix form
    /// (`"\(Self.unarmedSpokenLabel) \(title)."`) comes back. The trigger is
    /// a second session reachable from a list, not a redesign.
    static let unarmedSpokenLabel = "Agent unarmed. Set a provider in Routes."

    static func headerAccessibilityLabel(sessionID: String?,
                                         status: String,
                                         state: AgentState,
                                         disarmReason: String?) -> String {
        guard disarmReason == nil else { return Self.unarmedSpokenLabel }
        let title = sessionTitle(for: sessionID)
            .replacingOccurrences(of: Theme.separator, with: " ")
            .replacingOccurrences(of: "—", with: "not yet assigned")
        let badge = ReadinessBadge.forState(state, disarmReason: disarmReason)
        return "\(title.trimmingCharacters(in: .whitespaces)), \(status), \(badge.text)"
    }

    /// The header pill's badge, composed over (readiness, phase).
    private var headerBadge: ReadinessBadge {
        ReadinessBadge.forState(state, disarmReason: disarmReason)
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
                OrbGlyph(diameter: 24, mode: .dormant).padding(.bottom, 2)
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
            // 44pt is the touch-target FLOOR here too — but unlike the resume
            // bar (`HomeView.resumeBar`), this row ALSO overflows, and that is
            // measured rather than reasoned: `body(14)` on `.body` at AX5 is
            // 39.3pt of glyph and 46.9pt of LINE against a 44pt frame. Pinned
            // to `height` it clips the caret line — the field the user types
            // into, so the clip lands on their own words as they write them.
            // `testTheRealControlRowsAtAX5` asserts this direction strictly.
            .frame(minHeight: Theme.controlSize)
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
                // The symbol reports the state rather than always claiming a
                // mic: `.unavailable` renders a slashed mic and does not arm,
                // because a normal-looking mic button whose tap cannot work is
                // the silent non-action this cut exists to retire.
                accentButton(symbol: voiceSymbol,
                             label: voiceLabel,
                             enabled: voiceState.isActionable,
                             action: onVoice)
            } else {
                // `enabled` carries the disarm: with no provider the arrow is
                // visibly dead rather than absent. Hiding it would make the
                // composer look like a build without sending at all, which is
                // a different (and unfixable-looking) claim.
                accentButton(symbol: "arrow.up",
                             label: "Send",
                             enabled: SessionView.canSend(trimmedInput: trimmed,
                                                          disarmReason: disarmReason),
                             action: send)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// The mic glyph for the current voice state.
    ///
    /// `.listening` shows a stop, not a pulsing mic: the button IS the stop,
    /// and an animated mic would be a level meter with nothing metering it.
    private var voiceSymbol: String {
        switch voiceState {
        case .idle:        return "mic"
        case .listening:   return "stop.fill"
        case .denied:      return "mic.slash"
        case .unavailable: return "mic.slash"
        }
    }

    /// VoiceOver reads the STATE, because the glyph difference is the only
    /// thing a sighted operator has and a label of "Comms" in all four cases
    /// would make three of them indistinguishable without sight.
    private var voiceLabel: String {
        switch voiceState {
        case .idle:        return "Start voice input"
        case .listening:   return "Stop voice input"
        case .denied:      return "Microphone denied — open Settings"
        case .unavailable: return "Voice unavailable on this device"
        }
    }

    private func accentButton(symbol: String,
                              label: String,
                              enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.display(19, .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(minWidth: Theme.controlSize, minHeight: Theme.controlSize)
                .background(Theme.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
    }

    private func send() {
        // Guarded HERE as well as by `.disabled`, because `.onSubmit` fires on
        // the keyboard's return key and does not consult the button's disabled
        // state. Without this, hitting return would send a turn the UI just
        // said was impossible.
        let t = trimmed
        guard SessionView.canSend(trimmedInput: t, disarmReason: disarmReason) else { return }
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

/// The orb, at glyph scale.
///
/// PORTED. This was a gradient-disc placeholder until the `DeviceOrb` renderer
/// landed; it is now the real renderer at `OrbTuning.glyph` density (10 x 16 =
/// 187 points), which is the honest ceiling for a 24-34pt disc — a 1855-point
/// cloud cannot resolve at this size, so drawing it would be cost with no
/// visible return.
///
/// The two call sites (34pt session header, 24pt bubble avatar) pass the
/// agent's live mode through, so the glyph breathes with the same state
/// machine as a full-size orb rather than being decorative.
struct OrbGlyph: View {
    let diameter: CGFloat
    var mode: DeviceOrb.Mode = .dormant

    var body: some View {
        DeviceOrb(mode: mode, tuning: .glyph)
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}
