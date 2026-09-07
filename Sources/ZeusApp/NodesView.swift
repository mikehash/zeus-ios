import SwiftUI

/// NODES tab — the fleet pane.
///
/// Transcribed from `817b19d3d:docs/prototypes/mobile/zeus/ZeusApp.jsx`
/// :667-742 (the `tab === 'nodes'` arm), with the shared `Row` helper at
/// :377-400 and `Badge` at :341-347.
///
/// TRANSCRIPTION, NOT DERIVATION — as with `Theme.swift`. The prototype at
/// that ref is the authority; if it moves this file does not follow and
/// nothing goes red. The ref is cited so the drift is at least locatable.
///
/// ── GAP: ICON SUBSTITUTION (green, and not equivalent) ──────────────────
/// The prototype draws `lucide-react` glyphs. This tree has no vendored icon
/// set, so every icon below is an SF Symbol chosen by hand. The mapping is
/// recorded here because a substitution that renders is invisible at review:
///
///   Cpu       -> cpu                     Volume2  -> speaker.wave.2.fill
///   Database  -> cylinder.split.1x2      Sun      -> sun.max.fill
///   Wifi      -> wifi                    MicOff   -> mic.slash.fill
///   MapPin    -> mappin.and.ellipse      Power    -> power
///   Plus      -> plus                    Link2Off -> bolt.horizontal.circle
///
/// `Link2Off` (a broken link) has no close SF equivalent; the revoke row is
/// the ONE icon here that does not read as its source. Flagged rather than
/// silently accepted.
struct NodesView: View {

    /// :707 — the kitchen node's reachability. No transport exists in this
    /// tree, so this is state with no producer: it drives the whole pane and
    /// nothing outside the pane can currently change it. Deliberately kept
    /// as real state (not a constant) so the offline arm is reachable and
    /// reviewable, which a hardcoded `true` would make dead code.
    /// Link state, MEASURED. Was `@State private var nodeOnline = true` — a
    /// view-local literal whose own comment admitted *"nothing outside this
    /// view can do yet"*. It is now a parameter, so this view cannot claim a
    /// link it did not observe: there is no writable source of truth here to
    /// diverge from the probe.
    let link: LinkState

    /// Derived once. Every site below reads THIS rather than re-switching, so
    /// the pill, the tint, the subtitle and the disabled state cannot disagree
    /// about whether the node is up.
    private var nodeOnline: Bool { link.isLinked }
    @State private var muted = false
    @State private var volume: Double = 0.62
    @State private var brightness: Double = 0.40

    /// :711 — `route.name`.
    ///
    /// FETCHED, not vendored. This was `RouteCatalog.fallback` — one of eight
    /// hardcoded rows carrying model versions (see `Route.swift`; the strings
    /// are not repeated here — the leg greps this directory for them). The
    /// catalogue now comes from `GET /v1/providers`, so there is no local
    /// default to fall back to and **no selection until the operator makes
    /// one**: the row reads the gateway's ACTIVE provider when nothing is
    /// selected, and says so.
    /// RECEIVED, not owned. It was `@StateObject private var routes =
    /// RouteCatalogStore()` — a construction inside a view body, which has no
    /// commission store in scope and so could only ever resolve from the
    /// environment. `RootView` builds it from the one resolution and hands it
    /// down; `@ObservedObject` because the lifetime belongs to the parent.
    @ObservedObject var routes: RouteCatalogStore

    /// `:410` / `:408` — the two sheets. Separate flags: the prototype can
    /// have neither open, and nothing in either flow opens both.
    @State private var routeSheet = false
    @State private var confirmRevoke = false

    let onToast: (String) -> Void

    /// Opens the gateway editor for the arm this console was built from.
    /// The row's label is computed from that arm; the action is the same
    /// sheet for every arm — "switchable anytime" is the product ruling,
    /// and the row must exist for the operator who most needs the switch:
    /// the one already looking at a LOCAL console.
    /// No default — ②'s enumeration rule: `RootView` must pass it, and a
    /// defaulted closure would let a future call site ship the row dead.
    var onOpenGatewayEditor: (GatewayConfig) -> Void

    /// The arm the console was built from. RECEIVED, not re-derived —
    /// `RootView` measured it once at `init`; a second resolver call over
    /// the same store here would be two pictures of one decision.
    var resolution: GatewayConfig.Resolution

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                mobileNode
                kitchenNode
                enrollButton
                Text("ZEUS · NOVAXAI")
                    .font(Theme.mono(8.5))
                    .tracking(1.19)                       // 0.14em at 8.5pt
                    .foregroundStyle(Theme.w(0.2))
                    .padding(.top, 18)
                    .padding(.bottom, 8)
            }
            .padding(.bottom, 86)                          // :743 tab-bar gutter
        }
        // :754-812 — the sheet layer, drawn OVER the scroll view rather than
        // inside it. Inside, the panel would scroll away with the content.
        .overlay {
            if routeSheet { routeSelectSheet }
            if confirmRevoke { revokeConfirmSheet }
        }
        .animation(.easeOut(duration: 0.28), value: routeSheet)
        .animation(.easeOut(duration: 0.28), value: confirmRevoke)
        .task { await routes.load() }
    }

    // MARK: - The gateway row (label by arm)

    /// One label per arm, so the row says what the tap will DO rather than
    /// what the app wishes were true. `.absent` and `.local` share *use a
    /// remote gateway instead* deliberately: both are consoles with no
    /// remote endpoint, and the operator action is identical.
    ///
    /// Static for the reason every derivation in this tree is static: a
    /// SwiftUI body is not observable in-process, so the four-arm leg
    /// exercises this mapping directly.
    static func gatewayRowLabel(for config: GatewayConfig) -> String {
        switch config {
        case .absent:    return "NO GATEWAY — LINK ONE"
        case .local:     return "CORE — THIS PHONE"
        case .malformed: return "GATEWAY URL INVALID — FIX IT"
        case .resolved:  return "Change remote gateway"
        }
    }

    /// The value slot: the endpoint's host when resolved, the raw operand
    /// when malformed (so the operator can see WHAT is broken), and the
    /// un-set marker otherwise. Same aperture note as the label.
    static func gatewayRowValue(for config: GatewayConfig) -> String? {
        switch config {
        case .absent:                    return nil
        case .local:                     return "USE A REMOTE GATEWAY"
        case .malformed(let raw, _):     return raw
        case .resolved(let endpoint):    return endpoint.url.host ?? endpoint.url.absoluteString
        }
    }

    private var gatewayRowLabel: String  { Self.gatewayRowLabel(for: resolution.config) }
    private var gatewayRowValue: String? { Self.gatewayRowValue(for: resolution.config) }

    // MARK: - :754-790  route select

    private var routeSelectSheet: some View {
        SheetLayer(isPresented: $routeSheet,
                   title: "ROUTE SELECT",
                   subtitle: routes.state.subtitle) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(routes.state.routes) { rt in
                        RouteRow(route: rt, selected: rt.id == routes.selected?.id) {
                            let toast = routes.select(rt)
                            routeSheet = false
                            onToast(toast)
                        }
                    }
                    // NO VENDORED FALLBACK. When the fetch failed or the
                    // gateway is unconfigured there are zero rows and this
                    // line names WHY — rather than a stale hardcoded list,
                    // which would reintroduce the literal-model defect on the
                    // one path nobody tests.
                    if let reason = routes.state.emptyReason {
                        Text(reason)
                            .font(Theme.mono(8.5))
                            .tracking(0.8)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.w(0.35))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 22)
                    }
                }
            }
            Button {
                routeSheet = false
            } label: {
                Text("CLOSE")
                    .font(Theme.display(9.5, .bold))
                    .tracking(1.9)
                    .foregroundStyle(Theme.w(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.controlSize)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - :797-812  revoke confirm

    /// The confirm sheet. The ONLY site in this view that performs the
    /// destructive act — the row at `:196` merely raises the flag.
    ///
    /// ⚠️ WHAT THIS DOES TODAY: it toasts, exactly as the prototype does
    /// (`:801`). There is no token-invalidation call behind it because there is
    /// no such endpoint in `HTTPTransport` (`grep -rn "revoke" Sources` = this
    /// file only). Wiring a real revocation is a gateway feature, not a sheet
    /// feature. Stated here rather than implied, so the next reader does not
    /// assume access was actually revoked because a red button said REVOKE.
    private var revokeConfirmSheet: some View {
        SheetLayer(isPresented: $confirmRevoke,
                   title: "REVOKE ACCESS",
                   subtitle: "PRINCIPAL TOKEN INVALIDATED") {
            Text("NODE CONTINUES AUTONOMOUS · RE-ENROLL VIA PAIR CODE")
                .font(Theme.mono(9.5))
                .tracking(0.57)
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.w(0.4))
                .padding(.bottom, 14)

            Button {
                confirmRevoke = false
                onToast("ACCESS REVOKED — RE-ENROLL TO RECONNECT")
            } label: {
                Text("REVOKE")
                    .font(Theme.display(10.5, .bold))
                    .tracking(2.3)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    // Floor at 48 (the prototype's height), not a fixed 48:
                    // the label scales.
                    .frame(minHeight: 48)
                    .background(Color(hex: 0xE02020))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Button {
                confirmRevoke = false
            } label: {
                Text("ABORT")
                    .font(Theme.display(9.5, .bold))
                    .tracking(1.9)
                    .foregroundStyle(Theme.w(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.controlSize)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - :671-686  mobile node (the core)

    private var mobileNode: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                iconWell("cpu", tint: Theme.accent2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MOBILE NODE")
                        .font(Theme.display(11, .bold))
                        .tracking(2.2)                     // 0.2em at 11pt
                        .foregroundStyle(Theme.text)
                    Text("zeus-core 0.9 · this iphone")
                        .font(Theme.mono(9))
                        .tracking(0.9)
                        .foregroundStyle(Theme.r(0.7))
                }
                Spacer(minLength: 0)
                Badge(text: "ACTIVE", color: Theme.ok)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            VStack(spacing: 0) {
                // :682 — the value is `remote ? 'SYNC T-2MIN' : 'LIVE-LINK'`.
                // Same missing `remote` source as SessionView's statusLine;
                // pinned to the linked arm for the same reason.
                NodeRow(icon: "cylinder.split.1x2", label: "Mnemosyne",
                        value: "LIVE-LINK") {
                    onToast("MNEMOSYNE CONSISTENT — NO DELTA")
                }
                // No selection yet renders the gateway's own word for its
                // state, not an invented default.
                NodeRow(icon: "wifi", label: "Route",
                        value: routes.selected?.name ?? "TAP TO SELECT",
                        last: true) {
                    routeSheet = true
                }
                // THE GATEWAY ROW — present under EVERY config arm, labelled
                // by arm (the four-arm leg asserts the four labels differ).
                // It sits OUTSIDE any per-arm conditional because
                // "switchable anytime" is a product ruling about
                // reachability, not a rendering decision this view gets to
                // make: a row that exists only in `.absent` hides the switch
                // from the operator running `.local`, who is exactly the one
                // the ruling was made for.
                NodeRow(icon: "globe", label: gatewayRowLabel,
                        value: gatewayRowValue, last: true) {
                    onOpenGatewayEditor(resolution.config)
                }
            }
            .padding(.vertical, 5)
        }
        .background(
            LinearGradient(colors: [Theme.r(0.07), Theme.w(0.02)],
                           startPoint: .init(x: 0.25, y: 0.0),
                           endPoint: .init(x: 0.75, y: 1.0))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.r(0.3), lineWidth: Theme.hairline)
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - :689-731  optimus / kitchen node

    private var kitchenNode: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                iconWell("cpu", tint: nodeOnline ? Theme.accent2 : Theme.w(0.35))
                VStack(alignment: .leading, spacing: 2) {
                    Text("KITCHEN NODE")
                        .font(Theme.display(11, .bold))
                        .tracking(2.2)
                        .foregroundStyle(Theme.text)
                    // Was two literals — "kitchen · lan · gateway 0.9" and
                    // "unreachable · last seen t-12min". The second invented a
                    // last-seen time nothing recorded. Both arms now render
                    // the probe's own words.
                    Text(link.subtitle)
                        .font(Theme.mono(9))
                        .tracking(0.9)
                        .foregroundStyle(Theme.w(0.35))
                }
                Spacer(minLength: 0)
                Badge(text: link.badgeText, color: link.badgeColor)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if !nodeOnline {
                // :713 — the offline explainer. Now reachable: the probe
                // drives it. Previously dead code behind a `true` literal.
                Text("NODE AUTONOMOUS AT HOME · SAME AGENT, SAME MEMORY · MNEMOSYNE RECONCILES ON NEXT LINK")
                    .font(Theme.mono(9.5))
                    .tracking(0.38)
                    .lineSpacing(6.65)                     // line-height 1.7
                    .foregroundStyle(Theme.w(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            if nodeOnline {
                VStack(spacing: 12) {
                    NodeSlider(value: $volume, icon: "speaker.wave.2.fill")
                    NodeSlider(value: $brightness, icon: "sun.max.fill")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 14)

                micToggle
            }

            VStack(spacing: 0) {
                NodeRow(icon: "mappin.and.ellipse", label: "Ping node",
                        disabled: !nodeOnline) {
                    onToast("PING — KITCHEN NODE CHIMED")
                }
                NodeRow(icon: "power", label: "Restart",
                        disabled: !nodeOnline) {
                    onToast("NODE RESTART SEQUENCE INITIATED")
                }
                // :730 — opens the confirm sheet. The row itself is still
                // non-destructive: it only raises a flag. Every destructive
                // effect lives behind the REVOKE button in the sheet, so a
                // mis-tap here costs a dismissal and nothing else.
                NodeRow(icon: "bolt.horizontal.circle", label: "Revoke access",
                        danger: true, last: true) {
                    confirmRevoke = true
                }
            }
            .padding(.vertical, 2)
        }
        .background(Theme.w(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.w(0.08), lineWidth: Theme.hairline)
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - :717-726  mic hot/cold

    private var micToggle: some View {
        Button {
            muted.toggle()
            onToast(muted ? "KITCHEN MIC — COLD" : "KITCHEN MIC — HOT")
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "mic.slash.fill")
                    .font(Theme.body(16))
                    .foregroundStyle(muted ? Theme.danger : Theme.accent2)
                Text("KITCHEN MIC")
                    .font(Theme.body(14.5, .semibold))
                    .tracking(0.58)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Text(muted ? "COLD" : "HOT")
                    .font(Theme.mono(9))
                    .tracking(1.26)
                    .foregroundStyle(muted ? Color(hex: 0xFF8A80) : Theme.ok)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke((muted ? Theme.danger : Theme.ok)
                                        .opacity(Double(0x55) / 255.0),
                                    lineWidth: Theme.hairline)
                    )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.w(0.05))
                .frame(height: Theme.hairline)
        }
    }

    // MARK: - :735-741  enroll

    private var enrollButton: some View {
        Button {
            onToast("NODE ENROLLMENT — SCAN THE NEW DEVICE")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(Theme.display(14, .regular))
                Text("ENROLL NODE")
                    .font(Theme.display(9.5, .bold))
                    .tracking(1.9)                         // 0.2em at 9.5pt
            }
            .foregroundStyle(Theme.r(0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(style: StrokeStyle(lineWidth: Theme.hairline, dash: [4, 4]))
                .foregroundStyle(Theme.r(0.3))
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func iconWell(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(Theme.body(18))
            .foregroundStyle(tint)
            // 38, NOT Theme.controlSize: this well is decorative and carries no action,
            // so the 44 tap-target floor does not apply. Raising a non-interactive badge
            // to 44 is a layout change nobody asked for. Floor at what it is drawn at.
            .frame(minWidth: 38, minHeight: 38)
            .background(Theme.r(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Theme.r(0.3), lineWidth: Theme.hairline)
            )
    }
}

// MARK: - :377-400  Row

/// The prototype's `Row` helper. `disabled` dims to 0.35 and drops the tap;
/// `danger` recolours icon and label; `last` suppresses the divider.
struct NodeRow: View {
    let icon: String
    let label: String
    var value: String? = nil
    var danger: Bool = false
    var disabled: Bool = false
    var last: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: disabled ? {} : action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(Theme.body(16))
                    .foregroundStyle(danger ? Theme.danger : Theme.accent2)
                    // Width only, and it stays a width: this is a column slot, so every
                    // row must agree on it. The VERTICAL axis is unconstrained, which is
                    // the axis Dynamic Type grows — the glyph is free to get taller.
                    .frame(minWidth: 16)
                Text(label.uppercased())
                    .font(Theme.body(14.5, .semibold))
                    .tracking(0.58)                        // 0.04em at 14.5pt
                    .foregroundStyle(danger ? Color(hex: 0xFF8A80) : Theme.text)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(Theme.mono(9.5))
                        .tracking(1.14)
                        .foregroundStyle(Theme.w(0.4))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .overlay(alignment: .bottom) {
            if !last {
                Rectangle().fill(Theme.w(0.05)).frame(height: Theme.hairline)
            }
        }
    }
}

// MARK: - :349+  Slider

/// The prototype's draggable slider. Its pointer maths (`setFrom(clientX)`,
/// a `trackRef` and manual capture) is replaced by a SwiftUI drag gesture
/// over a measured track — SAME BEHAVIOUR, DIFFERENT MECHANISM, which is
/// worth saying because "ported" would overclaim it.
struct NodeSlider: View {
    @Binding var value: Double
    let icon: String

    private let track: CGFloat = 4
    private let knob: CGFloat = 14

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(Theme.body(15))
                .foregroundStyle(Theme.w(0.45))
                // Width only — column slot, same as above. The vertical axis is free.
                .frame(minWidth: 18)

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.w(0.08)).frame(height: track)
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: max(0, min(1, value)) * w, height: track)
                    Circle()
                        .fill(Theme.text)
                        .frame(width: knob, height: knob)
                        .offset(x: max(0, min(1, value)) * w - knob / 2)
                }
                .frame(height: knob)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard w > 0 else { return }
                            value = max(0, min(1, g.location.x / w))
                        }
                )
            }
            .frame(height: knob)
        }
    }
}
