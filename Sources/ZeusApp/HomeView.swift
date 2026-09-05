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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                identity
                LinkCard(state: link.state, onRetry: { Task { await link.probeOnce() } })
                statusGrid
            alertsRow
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
        return "OPERATOR · \(name.isEmpty ? "UNNAMED" : name.uppercased())"
    }

    // MARK: - Status grid

    /// Four cells, each sourced from a live surface and each labelled with the
    /// surface it reads. `AGENT` is engine phase; `LINK` is topology. They are
    /// deliberately NOT collapsed into one indicator: an idle agent behind an
    /// unreachable gateway is `NOMINAL` and `REMOTE` simultaneously, both true,
    /// and folding them would pick one to hide.
    private var statusGrid: some View {
        HStack(spacing: 10) {
            StatCell(caption: "AGENT", value: session.state.badgeText, tint: session.state.badgeColor)
            StatCell(caption: "LINK", value: link.state.badgeText, tint: link.state.badgeColor)
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

    var body: some View {
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption): \(value)")
    }
}
