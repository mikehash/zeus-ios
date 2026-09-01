import SwiftUI

/// Commissioning — the operator's six steps.
///
/// Transcribed from `817b19d3d:docs/prototypes/mobile/zeus/ZeusCommissioning.jsx`
/// (658 lines). Step list at :303, narration deck at :305-312, orb sizing at
/// :392-393, transitions at :375/:382/:386.
///
/// The consumer flow is `splash → welcome → scan → wifi → pair → room → done`.
/// This is a *different* six: **auth and routes replace wifi and pair**,
/// because the operator flow assumes the core matters more than any one node.
/// The narration says so explicitly — the phone core is already live before
/// anything is enrolled.

// MARK: - Step machine

/// `STEPS` at :303. Ordered, exhaustive, and `CaseIterable` so the progress
/// rail's denominator is derived rather than typed — a hardcoded `6` is a
/// number that goes stale silently when a step is added.
enum CommissioningStep: String, CaseIterable {
    case welcome, auth, routes, nodes, callsign, done

    /// `NARRATION` at :305-312, verbatim including the typographic
    /// apostrophes — they are in the source and the TTS pronounces them
    /// identically, so changing them would be an unforced divergence.
    var narration: String {
        switch self {
        case .welcome:
            return "Zeus core is live on this phone. Commissioning takes under a minute — let’s light it up."
        case .auth:
            return "First — you. Authenticate as operator."
        case .routes:
            return "Now my brainstem. Pick how I reach the models."
        case .nodes:
            return "Any hardware to enroll? Scan a node — or skip. I run fine solo."
        case .callsign:
            return "Last thing. What do I call you on comms?"
        case .done:
            return "All systems nominal. I’m yours, operator."
        }
    }

    /// :392 — 290 on the bookend steps, 185 in the middle.
    var orbSize: CGFloat {
        (self == .welcome || self == .done) ? 290 : 185
    }

    /// :393 — `nodes` is the only step that idles in `thinking`; the caller
    /// overrides with `.speaking` while the caption is still revealing.
    var idleOrbMode: DeviceOrb.Mode {
        self == .nodes ? .thinking : .dormant
    }
}

/// What commissioning produces. The whole point of the flow is this value.
struct Commission: Equatable {
    enum Route: String { case managed, byok }

    var route: Route = .managed
    var callsign: String = ""
    var nodeEnrolled: Bool = false

    /// The `done` summary line at :623+ — `zeus core · 11 routes · managed ·
    /// 1 node enrolled · operator miguel`, or `byok routes` / `solo`.
    var summary: String {
        let routeText = route == .managed ? "11 routes · managed" : "byok routes"
        let nodeText = nodeEnrolled ? "1 node enrolled" : "solo"
        let operatorText = callsign.isEmpty ? "operator" : "operator \(callsign.lowercased())"
        return "zeus core · \(routeText) · \(nodeText) · \(operatorText)"
    }
}

// MARK: - Host

struct CommissioningView: View {
    /// Called once, on leaving `done`. The parent owns what happens next.
    let onComplete: (Commission) -> Void

    @StateObject private var narrator = Narrator()
    @State private var step: CommissioningStep = .welcome
    @State private var commission = Commission()
    @State private var authed = false
    @State private var scanning = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            backdrop.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                DeviceOrb(mode: orbMode, level: narrator.isNarrating ? 0.7 : 0.2)
                    .frame(width: step.orbSize, height: step.orbSize)
                    .animation(.easeInOut(duration: 0.4), value: step.orbSize)
                caption
                Spacer(minLength: 0)
                stepContent
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { narrator.narrate(step.narration) }
        .onChange(of: step) { _, new in narrator.narrate(new.narration) }
        .onDisappear { narrator.stop() }
    }

    private var orbMode: DeviceOrb.Mode {
        narrator.isNarrating ? .speaking : step.idleOrbMode
    }

    // MARK: Chrome

    /// Progress rail + voice toggle. :455-465.
    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(Array(CommissioningStep.allCases.enumerated()), id: \.offset) { index, _ in
                    Capsule()
                        .fill(index <= stepIndex ? Theme.accent : Theme.w(0.12))
                        .frame(height: 2)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: stepIndex)

            Button {
                narrator.voiceOn.toggle()
            } label: {
                Image(systemName: narrator.voiceOn ? "speaker.wave.2" : "speaker.slash")
                    .font(.system(size: 15))
                    .foregroundStyle(narrator.voiceOn ? Theme.accent2 : Theme.w(0.4))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(narrator.voiceOn ? Theme.r(0.1) : Theme.w(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(narrator.voiceOn ? Theme.r(0.4) : Theme.r(0.2), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            // The label states the ACTION, not the state — VoiceOver reads it
            // as a command, and a caption-only user must still be told this
            // control does not gate the text.
            .accessibilityLabel(narrator.voiceOn ? "Mute narration voice" : "Unmute narration voice")
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    private var stepIndex: Int {
        CommissioningStep.allCases.firstIndex(of: step) ?? 0
    }

    /// The caption block with its blinking caret (:492-498). Rendered from
    /// `narrator.caption` only — never from the synthesizer.
    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(narrator.caption)
                .font(Theme.body(17))
                .foregroundStyle(Theme.w(0.82))
                .multilineTextAlignment(.center)
            if narrator.isNarrating {
                Rectangle()
                    .fill(Theme.accent2)
                    .frame(width: 2.5, height: 17)
                    .opacity(0.9)
            }
        }
        .frame(minHeight: 72, alignment: .top)
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(narrator.caption)
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            PrimaryButton("INITIALIZE", glyph: "arrow.right") { step = .auth }

        case .auth:
            if authed {
                // Replaced in place — no modal, no page change (:509-515).
                HStack(spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Theme.ok)
                    Text("OPERATOR VERIFIED · MIGUEL")
                        .font(Theme.mono(11))
                        .tracking(1.4)
                        .foregroundStyle(Theme.ok)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .fill(Theme.ok.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.corner)
                                .stroke(Theme.ok.opacity(0.33), lineWidth: 1)
                        )
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                VStack(spacing: 0) {
                    PrimaryButton("CONTINUE WITH PASSKEY", glyph: "touchid", action: doAuth)
                    QuietButton("USE NOVAXAI ID", action: doAuth)
                }
            }

        case .routes:
            VStack(spacing: 10) {
                RouteCard(
                    title: "MANAGED — NOVA CREDITS",
                    copy: "11 routes, zero keys. Metered via Atlas. Recommended.",
                    selected: commission.route == .managed
                ) { commission.route = .managed }

                RouteCard(
                    title: "BYOK — OWN KEYS",
                    copy: "Direct to providers. Keys stay in the secure enclave.",
                    selected: commission.route == .byok
                ) { commission.route = .byok }

                if commission.route == .byok {
                    // The hint is part of the contract: the key field here is
                    // not the only place keys can be added.
                    Text("MORE ROUTES ANYTIME IN NODES → ROUTE")
                        .font(Theme.mono(8.5))
                        .tracking(1.0)
                        .foregroundStyle(Theme.w(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }

                // The CTA states whether a network round-trip will happen.
                // BYOK validates a key; managed does not. Same button, and
                // the label is the only warning the operator gets.
                PrimaryButton(
                    commission.route == .byok ? "VALIDATE + CONTINUE" : "CONTINUE",
                    glyph: "arrow.right"
                ) { step = .nodes }
            }
            .animation(.easeInOut(duration: 0.25), value: commission.route)

        case .nodes:
            VStack(spacing: 0) {
                PrimaryButton(scanning ? "SCANNING…" : "SCAN NODE", glyph: "viewfinder") {
                    scanning = true
                }
                // The solo path must reach `done` fully functional — a node
                // is an enhancement to the core, not a prerequisite for it.
                QuietButton("SKIP — RUN SOLO") {
                    scanning = false
                    commission.nodeEnrolled = false
                    step = .callsign
                }
            }

        case .callsign:
            VStack(spacing: 10) {
                TextField("", text: $commission.callsign, prompt:
                    Text("CALLSIGN").font(Theme.mono(12)).foregroundStyle(Theme.w(0.2))
                )
                .font(Theme.mono(14))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .fill(Theme.w(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.corner)
                                .stroke(Theme.r(0.25), lineWidth: 1)
                        )
                )
                .accessibilityLabel("Operator callsign")

                PrimaryButton("CONFIRM", glyph: "arrow.right") { step = .done }
            }

        case .done:
            VStack(spacing: 14) {
                Text(commission.summary)
                    .font(Theme.mono(9.5))
                    .tracking(1.0)
                    .foregroundStyle(Theme.w(0.45))
                    .multilineTextAlignment(.center)

                PrimaryButton("ENTER CONSOLE", glyph: "arrow.right") {
                    narrator.stop()
                    onComplete(commission)
                }
            }
        }
    }

    /// :371-375 — auth resolves, the block swaps in place, then the flow
    /// advances after 1.2s. The delay is deliberate: the operator is meant
    /// to read the verified line, so it is not a spinner artefact.
    private func doAuth() {
        withAnimation { authed = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            step = .routes
        }
    }

    private var backdrop: some View {
        ZStack {
            RadialGradient(
                colors: [Theme.accent.opacity(0.07), .clear],
                center: UnitPoint(x: 0.5, y: 0.30), startRadius: 0, endRadius: 420
            )
            RadialGradient(
                colors: [Theme.accentDeep.opacity(0.04), .clear],
                center: UnitPoint(x: 0.5, y: 0.92), startRadius: 0, endRadius: 340
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Controls

/// `primaryBtn` at :314-319 — 52pt, gradient fill, ink-dark glyph, crimson bloom.
private struct PrimaryButton: View {
    let title: String
    let glyph: String
    let action: () -> Void

    init(_ title: String, glyph: String, action: @escaping () -> Void) {
        self.title = title
        self.glyph = glyph
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(Theme.display(11, .bold))
                    .tracking(2.6)
                if !glyph.isEmpty {
                    Image(systemName: glyph).font(.system(size: 14, weight: .bold))
                }
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(Theme.accentGradient)
                    .shadow(color: Theme.r(0.35), radius: 12)
            )
        }
        .buttonStyle(.plain)
    }
}

/// `quietBtn` at :320+ — the secondary that is never a competing CTA.
private struct QuietButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono(10))
                .tracking(1.8)
                .foregroundStyle(Theme.w(0.4))
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The routes fork (:521-558). Selection is the border and fill, not a
/// checkmark — the card *is* the control.
private struct RouteCard: View {
    let title: String
    let copy: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.display(10, .bold))
                    .tracking(2.0)
                    .foregroundStyle(selected ? Theme.accent : Theme.w(0.55))
                Text(copy)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.w(selected ? 0.75 : 0.45))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(selected ? Theme.r(0.08) : Theme.w(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .stroke(selected ? Theme.r(0.5) : Theme.w(0.08), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
