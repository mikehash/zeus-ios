import SwiftUI

/// The ZEUS tab — the app's cold-start destination.
///
/// It was `PlaceholderPane(title: "ZEUS", detail: "agent")`: two centred
/// strings. That was defensible while the tab was somewhere a user navigated
/// TO, and stopped being defensible the moment `LaunchArgs.initialTab`
/// resolved to `.zeus` unconditionally in release. Every commissioned
/// operator, on every cold start, lands here. Restoring a commission into an
/// empty pane restores the operator to nothing.
///
/// Every value on this screen is derived. There is no literal status string,
/// no invented count, and no timestamp that nothing recorded — the three
/// defects already removed from `RootView`, `NodesView` and the session
/// header. Where a value is genuinely unknown the screen says so with an
/// em-dash rather than a plausible number, because a fabricated value has the
/// SHAPE of data and is read as a measurement.
struct HomeView: View {
    @Environment(\.commission) private var commission
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Link topology. The same monitor the pill and NODES read, so three
    /// surfaces cannot disagree about whether the gateway answers.
    @ObservedObject var link: LinkMonitor

    /// Engine phase and transcript. Read-only: this view has no method that
    /// mutates either, which is the property that kept a second transcript
    /// writer out of `RootView`.
    @ObservedObject var session: SessionEngine

    /// Push state. Read, never owned — the token arrives on the app delegate
    /// and the registrar that receives it must outlive this view.
    @ObservedObject var push: PushRegistrar

    /// Hands the operator to the SESSION tab. The home screen starts a
    /// conversation; it does not host one.
    let onOpenSession: () -> Void

    /// Opens the gateway editor sheet, handed the config arm the console was
    /// built from. The pill is the affordance; the sheet itself lives in
    /// `RootView`, which owns the one `@State` flag — a second owner would
    /// mean two truths about whether the editor is open. No default — ②'s
    /// enumeration rule: a defaulted closure lets a call site ship a row
    /// that does nothing, and the compiler must enumerate the wiring.
    var onOpenGatewayEditor: (GatewayConfig) -> Void

    /// Pending tool executions awaiting an answer. Read-only here; the store
    /// owns the queue and re-reads the gateway after every decision.
    @ObservedObject var approvals: ApprovalsStore

    /// The `Resolution` the whole console was built from — the same one
    /// `RootView` measured at `init`. Read here (not re-derived) so the LINK
    /// pill's open-action can label the editor with the config's arm WITHOUT
    /// a second resolver call: two calls over one store is two pictures of
    /// one decision.
    let resolution: GatewayConfig.Resolution

    /// The live provider catalogue — RECEIVED, not owned. `RootView:104` holds
    /// the one `RouteCatalogStore`; NODES already reads it (`NodesView:349`).
    /// This screen is a SECOND READER of that store, not a second source: the
    /// prototype's `ROUTES` array is eight hardcoded entries carrying invented
    /// `P50 180MS` latencies, and transcribing it would put a fabricated
    /// measurement on the cold-start screen — the `t-12min` defect wearing a
    /// catalogue. The pill renders what the gateway enumerated or the
    /// catalogue's own word for why it enumerated nothing.
    @ObservedObject var routes: RouteCatalogStore

    /// Mic phase. Read, never owned: `RootView:61` holds the one `VoiceInput`
    /// so the ZEUS tab and the SESSION composer cannot disagree about whether
    /// the tap is installed.
    let voiceState: VoiceState

    /// Live microphone energy `0...1` from the tap already in hand
    /// (`Voice.swift:269`, landed `9e06d1a`). Passed as a value rather than
    /// observed so this view redraws with the engine's phase, not at buffer
    /// rate.
    let voiceLevel: Double

    /// The COMMS action — `VoiceInput.toggle`. No default: a defaulted closure
    /// lets a call site ship a button that does nothing, and the compiler must
    /// enumerate the wiring.
    var onVoice: () -> Void

    /// Opens the same route-selection surface NODES draws. The sheet has one
    /// owner; this is the affordance.
    var onOpenRoutes: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                identity
                agent
                routePill
                agentControls
                LinkCard(state: link.state, onRetry: { Task { await link.probeOnce() } })
                statusGrid
                alertsRow
                ApprovalsSection(store: approvals, now: Date())
                resume
                activityFeed
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
    }

    // MARK: - Identity

    /// `OPERATOR · <callsign>` — from the restored commission, not a literal.
    ///
    /// A commission with an empty callsign is possible: the flow's callsign
    /// step can be completed blank. That renders as `OPERATOR · UNNAMED`
    /// rather than as a trailing separator with nothing after it, because a
    /// dangling `·` reads as a rendering bug and not as an empty field.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ZEUS")
                .font(Theme.display(34))
                .tracking(Theme.displayTracking)
                .foregroundStyle(Theme.text)

            Text(operatorLine)
                .font(Theme.mono(10))
                .tracking(1.0)
                .foregroundStyle(Theme.r(0.75))

            Text(commission.summary.uppercased())
                .font(Theme.mono(9.5))
                .tracking(0.8)
                .foregroundStyle(Theme.w(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    var operatorLine: String { Self.operatorLine(for: commission.callsign) }

    /// Static so the derivation is exercisable without a rendered view.
    /// SwiftUI bodies are not observable in-process and `@Environment` cannot
    /// be injected into a value type from a test, so a derivation left as an
    /// instance property reading the environment would have been guardable
    /// only through a screenshot — which is how the three literal-status
    /// defects survived as long as they did.
    static func operatorLine(for callsign: String) -> String {
        let name = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        return Theme.joined(["OPERATOR", name.isEmpty ? "UNNAMED" : name.uppercased()])
    }

    // MARK: - The agent

    /// The orb — the prototype's home-screen centrepiece (`ZeusApp.jsx:544`).
    ///
    /// It was absent here (`grep -c DeviceOrb HomeView.swift` = 0 at
    /// `4798cc2`) while the renderer was already built and already used at
    /// `Commissioning:110` and `SessionView:332`. This adds a third call site;
    /// it adds no renderer, no mode, and no data source.
    ///
    /// NO BADGE UNDER IT, deliberately, and the reason is the accessibility
    /// split already stated in `AccessibilityTests:28-40`: the orb carries
    /// `DeviceOrb.Mode` (three energies) and the badge carries `AgentState`
    /// (four phases), because `orbMode` folds `listening` and `responding`
    /// into `.speaking`. The `AGENT` cell of `statusGrid` is this screen's
    /// badge — it publishes `session.state.badgeText`, the recoverable phase.
    /// Rendering a second badge here would put the same string on screen
    /// twice and still leave the phase unrecoverable from the picture.
    private var agent: some View {
        DeviceOrb(mode: session.state.orbMode,
                  level: Self.orbLevel(for: session.state,
                                       voiceState: voiceState,
                                       micLevel: voiceLevel))
            .frame(width: Self.orbDiameter, height: Self.orbDiameter)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement()
            .accessibilityLabel("Zeus orb")
            .accessibilityValue(DeviceOrb.accessibilityValue(for: session.state.orbMode))
    }

    // MARK: - Route pill

    /// `ROUTE · <name>` under the orb (`zeus-mobile-app1.jsx:585-591`).
    ///
    /// The value is the catalogue's, never a literal. `routeValue` is static
    /// for the reason every other derivation in this file is: a SwiftUI body
    /// is not observable in-process, so a derivation left inside one is
    /// guardable only by screenshot.
    private var routePill: some View {
        Button(action: onOpenRoutes) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(Theme.mono(9))
                Text(Self.routeValue(selected: routes.selected,
                                     state: routes.state))
                    .font(Theme.mono(9))
                    .tracking(1.0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(Theme.accent2)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.accent.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityLabel("Route")
        .accessibilityValue(Self.routeValue(selected: routes.selected,
                                            state: routes.state))
    }

    /// Selection first, then the catalogue's own reason, then the invitation.
    ///
    /// NO LITERAL PROVIDER LIST and no invented latency. The prototype ships
    /// eight hardcoded routes carrying `P50 180MS · DIRECT` strings that
    /// nothing measured; those are a fabricated measurement in a slot the eye
    /// reads as telemetry, and they are not ported. Where the catalogue is
    /// empty the pill says WHY in the catalogue's words (`emptyReason`)
    /// instead of naming a provider the gateway never enumerated.
    static func routeValue(selected: Route?, state: RouteCatalogState) -> String {
        if let name = selected?.name, !name.isEmpty {
            return Theme.joined(["ROUTE", name.uppercased()])
        }
        if let why = state.emptyReason, !why.isEmpty {
            return Theme.joined(["ROUTE", why])
        }
        return Theme.joined(["ROUTE", "TAP TO SELECT"])
    }

    // MARK: - Controls

    /// COMMS · BROADCAST · PING (`zeus-mobile-app1.jsx:597-640`).
    ///
    /// COMMS is wired to the one `VoiceInput`; the other two are TERMINALLY
    /// DISABLED, and the reason is the strongest kind of absence there is.
    private var agentControls: some View {
        VStack(spacing: 7) {
            HStack(spacing: 14) {
                controlButton(symbol: Self.commsSymbol(for: voiceState),
                              label: Self.commsLabel(for: voiceState),
                              enabled: voiceState.isActionable,
                              filled: true,
                              action: onVoice)
                controlButton(symbol: "megaphone",
                              label: Self.absentVerbLabel(control: "Broadcast"),
                              enabled: false,
                              filled: false,
                              action: {})
                controlButton(symbol: "mappin.and.ellipse",
                              label: Self.absentVerbLabel(control: "Ping node"),
                              enabled: false,
                              filled: false,
                              action: {})
            }
            HStack(spacing: 14) {
                ForEach(Self.controlCaptions, id: \.self) { caption in
                    Text(caption)
                        .font(Theme.display(7, .bold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.w(0.35))
                        .frame(width: Self.controlSide)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            if let line = Self.controlsNote(voiceState: voiceState) {
                Text(line)
                    .font(Theme.mono(9))
                    .tracking(0.6)
                    .foregroundStyle(Theme.w(0.4))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    static let controlSide: CGFloat = 58
    static let controlCaptions = ["COMMS", "BROADCAST", "PING"]

    /// The COMMS glyph reports the mic's state rather than always claiming a
    /// mic — the same rule `SessionView:488` already applies, reused so two
    /// screens cannot draw different pictures of one `VoiceInput`.
    static func commsSymbol(for state: VoiceState) -> String {
        switch state {
        case .idle:        return "mic"
        case .listening:   return "stop.fill"
        case .denied:      return "mic.slash"
        case .unavailable: return "mic.slash"
        }
    }

    static func commsLabel(for state: VoiceState) -> String {
        switch state {
        case .idle:        return "Start voice input"
        case .listening:   return "Stop voice input"
        case .denied:      return "Microphone denied — open Settings"
        case .unavailable: return "Voice unavailable on this device"
        }
    }

    /// BROADCAST and PING: DISABLED, TERMINALLY, ON VERB-ABSENCE.
    ///
    /// The census that settles it, POS/NEG controlled in one invocation:
    ///
    /// ```
    /// broadcast/chime/pingNode/wakeNode/restartNode   app=0  ffi=0   (subject)
    /// session                                         app=361 ffi=49 (POS ctl)
    /// zzzNoVerb                                       app=0  ffi=0   (NEG ctl)
    /// FFI surface: hasProvider indexSize listModels messages remember
    ///              search send sessions setProvider   ← no node verb
    /// ```
    ///
    /// A live POS beside a dead NEG makes this a PROVEN ABSENCE rather than an
    /// unfound one. The prototype's handlers are literal toasts — `BROADCAST
    /// SENT — KITCHEN NODE`, `PING — KITCHEN NODE CHIMED`, and on the offline
    /// arm `NODE UNREACHABLE — QUEUED FOR NEXT LINK`, which additionally
    /// claims a queue that does not exist. Shipping them would put two
    /// controls on the cold-start screen asserting a node was reached and made
    /// a sound while nothing left the phone.
    ///
    /// NOT CONDITIONED ON `link.isLinked`, deliberately, and `LinkMonitor` IS
    /// in scope here (`:24`) with `LinkState.unreachable(host:reason:)` — so
    /// the temptation is concrete, not hypothetical. A control that reads link
    /// state to decide its enablement ASSERTS THE VERB EXISTS and is merely
    /// unreachable. It does not exist, and that assertion is the same costume
    /// defect one layer up. A missing verb is terminal, exactly as
    /// `VoiceState.unavailable` is terminal (`Voice.swift:117`, `canArm` false
    /// at `:139`) and for the same stated reason: re-tapping cannot change it.
    /// An unreachable host is NOT terminal, which is why the two arms differ.
    static func absentVerbLabel(control: String) -> String {
        "\(control) — no transport on this build"
    }

    /// The one line under the row. Mic state first (the operator can fix a
    /// denial), otherwise the verb-absence note.
    static func controlsNote(voiceState: VoiceState) -> String? {
        if let line = voiceState.line { return line }
        return Theme.joined(["BROADCAST", "PING — NO NODE TRANSPORT ON THIS BUILD"])
    }

    private func controlButton(symbol: String,
                               label: String,
                               enabled: Bool,
                               filled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.display(21, .bold))
                .foregroundStyle(filled && enabled ? Theme.bg : Theme.accent2)
                .frame(width: Self.controlSide, height: Self.controlSide)
                .background(filled && enabled
                            ? AnyShapeStyle(Theme.accentGradient)
                            : AnyShapeStyle(Theme.w(0.04)))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.accent.opacity(enabled ? 0.55 : 0.25),
                                lineWidth: 1)
                )
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    /// 250 in the prototype (`:543`). Held as a fixed square rather than a
    /// floor because the orb is a `Canvas` and carries no type: the
    /// floor-not-ceiling ruling that governs every other frame in this file
    /// exists so scaled TEXT is never clipped by a fixed parent, and there is
    /// no text inside this one. It is a drawing, and a drawing has a size.
    static let orbDiameter: CGFloat = 250

    /// Energy handed to the renderer, derived from the engine phase.
    ///
    /// TWO ARMS, AND WHICH ONE IS HONEST DEPENDS ON WHETHER THE TAP IS
    /// INSTALLED. While `voiceState == .listening` this IS an audio amplitude:
    /// `VoiceInput.level` is RMS over the very buffer the recognizer receives
    /// (`Voice.swift:274`, landed `9e06d1a`), so the orb renders measured
    /// energy and the prototype's live meter is satisfied by real data.
    ///
    /// In every other phase NOTHING ON THIS SCREEN METERS ANYTHING, and a
    /// plausible oscillating number would be the `t-12min` defect wearing a
    /// renderer argument — a fabricated value in a slot the eye reads as a
    /// measurement. So the non-listening arm stays the two-valued constant.
    /// The prototype does the opposite at both sites: its stage orb (`:913`)
    /// passes no `level` at all, and the one orb that meters is fed
    /// `Math.random() * 0.7 + 0.15` (`:430`). Neither is ported.
    ///
    /// So it is a two-valued constant over a REAL reading, which is exactly
    /// the shape `Commissioning:110` already uses (`narrator.isNarrating ?
    /// 0.7 : 0.2`). `level` is read by the renderer only in `.speaking`
    /// (`DeviceOrb.swift:70`), so the value differs only where it is
    /// observable, and the two speaking phases are deliberately equal: the
    /// orb's alphabet is energy, and it does not claim to tell them apart.
    ///
    /// Static for the reason the six other derivations here are static — a
    /// SwiftUI body is not observable in-process, so anything computed inside
    /// one is guardable only by screenshot.
    static func orbLevel(for state: AgentState,
                         voiceState: VoiceState,
                         micLevel: Double) -> Double {
        // ARM ONE — the tap is installed, so there IS an audio amplitude and
        // the orb renders it. Clamped at the seam: `DeviceOrb.level` is
        // documented `0...1` and a renderer argument may not inherit a
        // producer's range by assumption.
        if voiceState == .listening { return min(max(micLevel, 0), 1) }

        // ARM TWO — nothing is metering, so the value is the two-valued
        // constant over a real reading it always was.
        switch state {
        case .listening, .responding: return 0.7
        case .thinking, .ambient:     return 0.2
        }
    }

    // MARK: - Status grid

    /// The AGENT cell's badge, composed over (readiness, phase).
    ///
    /// One derivation shared with the session header pill and the screen-reader
    /// label — see `ReadinessBadge`. Held as a property rather than inlined so
    /// the cell reads the pair and cannot take the text from one source and the
    /// tint from another.
    private var agentBadge: ReadinessBadge {
        ReadinessBadge.forState(session.state,
                                disarmReason: resolution.config.disarmReason)
    }

    /// Four cells, each sourced from a live surface and each labelled with the
    /// surface it reads. `AGENT` is engine phase COMPOSED WITH readiness;
    /// `LINK` is topology. They are deliberately NOT collapsed into one
    /// indicator: an idle agent behind an unreachable gateway is `NOMINAL` and
    /// `REMOTE` simultaneously, both true, and folding them would pick one to
    /// hide. Readiness is folded into AGENT rather than given a fifth cell
    /// because an unarmed core makes the phase MEANINGLESS, not merely
    /// accompanied by bad news.
    private var statusGrid: some View {
        HStack(spacing: 10) {
            // AGENT reads the READINESS-COMPOSED badge, not the raw phase.
            // `session.state` alone is the engine's phase, and an idle engine
            // is `.ambient` whether or not the core has a provider — which is
            // how this cell rendered NOMINAL in green above a composer that
            // could not send. `resolution.config.disarmReason` is the same
            // value the composer gates on, so the two cannot disagree.
            StatCell(caption: "AGENT", value: agentBadge.text, tint: agentBadge.tint)
            // LINK is the one control in the grid: the pill that opens the
            // gateway editor. The census leg (`HomeViewTests`) holds this at
            // exactly one `action:` across the four sites.
            StatCell(caption: "LINK", value: link.state.badgeText,
                     tint: link.state.badgeColor,
                     action: { onOpenGatewayEditor(resolution.config) })
            StatCell(caption: "TURNS", value: turnsValue, tint: Theme.w(0.8))
            StatCell(caption: "LATENCY", value: latencyValue, tint: Theme.w(0.8))
        }
    }

    /// ALERTS. Its own row rather than a fifth grid cell because it carries a
    /// detail line the four-cell grid has no room for — and the detail line is
    /// the part that keeps it honest: `PENDING · allowed, no device token yet`
    /// is the state a build with no APNs entitlement lives in permanently, and
    /// a bare badge would render it indistinguishably from ON.
    private var alertsRow: some View {
        HStack(spacing: 8) {
            Text("ALERTS")
                .font(Theme.mono(8.5, .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.w(0.5))
            Text(push.state.badgeText)
                .font(Theme.mono(11, .semibold))
                .tracking(0.6)
                .foregroundStyle(PushState.badgeColor(for: push.state))
            Text(push.state.detailLine)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.w(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            if push.state == .notDetermined {
                Button("ENABLE") { Task { await push.request() } }
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.barCorner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Alerts: \(push.state.badgeText). \(push.state.detailLine)")
    }

    /// Agent messages are the completed half of a turn; a streaming caret is
    /// counted only once it has stopped streaming. Counting user messages
    /// instead would increment before the gateway had answered anything.
    var turnsValue: String { Self.turnsValue(for: session.messages) }

    static func turnsValue(for messages: [Message]) -> String {
        String(messages.filter { $0.role == .agent && !$0.streaming }.count)
    }

    /// Measured round-trip to `/health`, or `—`. Never a remembered value: a
    /// latency from a probe that has since failed describes a gateway that is
    /// no longer answering.
    var latencyValue: String { Self.latencyValue(for: link.state) }

    static func latencyValue(for state: LinkState) -> String {
        if case let .linked(_, ms) = state { return "\(ms)MS" }
        return "—"
    }

    // MARK: - Resume

    /// The one action on the screen. Its label is a function of transcript
    /// state, so it cannot offer to "resume" a conversation that never
    /// started.
    private var resume: some View {
        Button(action: onOpenSession) {
            HStack(spacing: 10) {
                Image(systemName: session.messages.isEmpty ? "plus.message" : "arrow.uturn.forward")
                    .font(Theme.mono(13, .semibold))
                Text(resumeLabel)
                    .font(Theme.mono(11, .semibold))
                    .tracking(1.0)
                Spacer(minLength: 0)
                Text(lastLine)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.onAccent.opacity(0.7))
                    .lineLimit(1)
                    // Paired with `truncationMode` deliberately: shrink first,
                    // clip only when shrinking is exhausted. Now that Theme
                    // scales, a fixed frame plus tail-truncation alone loses
                    // characters off the END of the last line at AX5 — the
                    // most recent words, which is the half a reader wants.
                    .minimumScaleFactor(0.7)
                    .truncationMode(.tail)
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16)
            // `minHeight`, not `height`: 44pt is the TOUCH-TARGET FLOOR, not a
            // ceiling.
            //
            // THIS ROW DOES NOT OVERFLOW A FIXED 44pt FRAME ON ITS OWN AT AX5,
            // and an earlier version of this comment said it did. Measured on
            // the platform, not off Apple's published ladder: `mono(11)` on
            // `.caption` at AX5 is 35.0pt of glyph and 41.8pt of LINE, so the
            // line consumes 41.8 of 44 and clears by 2.2 — which is less than
            // this row's own horizontal padding, so any vertical padding at all
            // takes it over. The composer (`SessionView`'s `TextField`) is the one that
            // overflows outright (46.9). See `testTheRealControlRowsAtAX5`,
            // which asserts BOTH directions so the difference cannot be lost.
            //
            // So the edit here rests on the touch-target floor ALONE, and it is
            // correct on that argument whether or not a clip is ever observed.
            // A fixed frame cannot grow; a floor can. That is the whole claim.
            .frame(minHeight: Theme.controlSize)
            .frame(maxWidth: .infinity)
            .background(Theme.accentGradient)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(resumeLabel)
        .accessibilityHint("Opens the session tab")
    }

    var resumeLabel: String { Self.resumeLabel(for: session.messages) }

    static func resumeLabel(for messages: [Message]) -> String {
        messages.isEmpty ? "START A SESSION" : "RESUME SESSION"
    }

    /// A preview of the last transcript line, or empty. Empty rather than a
    /// placeholder sentence, because a placeholder in a preview slot is
    /// indistinguishable from a real short reply.
    var lastLine: String { Self.lastLine(for: session.messages) }

    static func lastLine(for messages: [Message]) -> String {
        guard let last = messages.last else { return "" }
        return last.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Activity

    /// The most recent telemetry frames, newest first. Reads `activity`, not
    /// `messages`: the transcript is what was said, this is what was done, and
    /// the model keeps them apart precisely so a view can choose.
    ///
    /// The empty state states a fact about this build — no turn has run — and
    /// does not fabricate history to fill the space.
    @ViewBuilder
    private var activityFeed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVITY")
                .font(Theme.mono(9, .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.w(0.5))

            if session.activity.isEmpty {
                Text("no activity this session")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.w(0.45))
                    .padding(.vertical, 10)
            } else {
                ForEach(recentActivity) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("·")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.r(0.8))
                        Text(item.label)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.w(0.7))
                            // Two lines is a budget calibrated at default size;
                            // the same label needs more of them once the type
                            // scales, so the budget scales with it.
                            .lineLimit(Theme.lineLimit(2, accessibilitySize: dynamicTypeSize.isAccessibilitySize))
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    /// Newest first, capped. The cap is a rendering decision and is applied
    /// AFTER reversing, so the newest frames survive it rather than the oldest.
    var recentActivity: [SessionActivity] { Self.recentActivity(from: session.activity) }

    /// Cap applied AFTER reversing: capping first renders the six OLDEST
    /// frames under a heading that says nothing about age.
    static func recentActivity(from activity: [SessionActivity]) -> [SessionActivity] {
        Array(activity.reversed().prefix(6))
    }
}

// MARK: - Link card

/// The link verdict, spelled out with its evidence, plus a manual re-probe.
///
/// The card names the endpoint and the reason. A pill can say REMOTE; only a
/// card has room to say which host and why, and "why" is the difference
/// between an operator fixing their config and an operator filing a bug.
struct LinkCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let state: LinkState
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(state.badgeColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.statusLine)
                    .font(Theme.mono(10, .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.text)
                Text(state.subtitle)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.w(0.55))
                    .lineLimit(Theme.lineLimit(2, accessibilitySize: dynamicTypeSize.isAccessibilitySize))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.r(0.9))
                    .frame(minWidth: Theme.controlSize, minHeight: Theme.controlSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Re-probe the gateway")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Stat cell

struct StatCell: View {
    let caption: String
    let value: String
    let tint: Color
    /// The control arm. Nil = read-only cell; non-nil = the whole cell is
    /// the button. Optional (not defaulted-away) so the two arms stay
    /// explicit at the call site: `action:` present means control.
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action = action {
                // Control arm: the identical body wrapped in a plain
                // button — full-cell hit area (`contentShape` covers the
                // padded frame), tap-target floor, the trait so assistive
                // tech reads it as what it is.
                Button(action: action) {
                    cellBody
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .frame(minHeight: Theme.controlSize)
                .accessibilityAddTraits(.isButton)
            } else {
                // Read-only arm: same body, no wrapper, no gesture.
                cellBody
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption): \(value)")
    }

    /// The shared cell body — the arms differ only by the wrapper, so any
    /// visual divergence between control and read-only cells is a defect
    /// in this file, not a styling decision elsewhere.
    private var cellBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(caption)
                .font(Theme.mono(8.5, .semibold))
                .tracking(1.0)
                // 0.5 rather than the 0.3 the prototype used at this size:
                // 8.5pt at 30% white fails contrast against `surface`, and
                // this is the smallest type in the app.
                .foregroundStyle(Theme.w(0.5))
            Text(value)
                .font(Theme.mono(11, .semibold))
                .tracking(0.6)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.barCorner, style: .continuous))
    }
}
