import SwiftUI

/// SETTINGS — the config surface.
///
/// ── WHY THIS FILE EXISTS ────────────────────────────────────────────────
/// merakizzz on build 192: *"I don't see any way to change my config, not the
/// llm, nothing. We need a tab for settings."* The controls he was looking for
/// existed — Provider, Gateway and Route shipped in 192 — but they lived at the
/// bottom of the NODES pane, under a fleet console and a search panel. A
/// control an operator cannot FIND is indistinguishable from one that is not
/// there, which is the same verdict the wiring census gave the dead retry
/// arrow one arc ago from the other direction.
///
/// ── MOVE, NOT MIRROR ────────────────────────────────────────────────────
/// The three rows are **moved** here, not duplicated. A mirrored row is a
/// second write path over one preference, and two write paths over one value
/// is exactly the drift Arc B closed when it extracted `RoutePicker` instead of
/// pasting a second copy into `NodesView`. NODES keeps ONE row — a breadcrumb
/// that raises to this tab and writes nothing — so the operator who met those
/// rows in 192 still finds them from where he left them.
///
/// ── WHAT TRAVELLED, AND WHAT DID NOT ────────────────────────────────────
/// `routes` travelled with the Route row, and with it the `.task` that LOADS
/// the catalogue — that is a behavioural line, not a relocation, and it is
/// legged as one. `resolution` did NOT travel: two of its ten readings in
/// `NodesView` (the readiness badge and the recall aperture) have nothing to do
/// with the gateway row, so it is declared on both views and read by each for
/// its own reason. Each of the ten occurrences was checked rather than assumed
/// to belong to the row that looked like its owner.
struct SettingsView: View {

    /// RECEIVED, not owned — `RootView:104` builds the one store and NODES no
    /// longer reads it. This view now owns the `.task` that loads it.
    @ObservedObject var routes: RouteCatalogStore

    let onToast: (String) -> Void

    /// Opens the gateway editor for the arm this console was built from.
    /// Un-defaulted deliberately: a defaulted closure would let a future call
    /// site ship the row dead, which is the defect class this app keeps
    /// finding in new costumes.
    var onOpenGatewayEditor: (GatewayConfig) -> Void

    /// Raises the route picker. RAISE-ONLY: this view cannot commit a routes
    /// choice, because committing means write → invalidate → re-arm as one
    /// act, and only `RootView` holds all three of the store, the keys and the
    /// resolution. A commit here would half-happen.
    var onOpenRoutes: () -> Void

    var resolution: GatewayConfig.Resolution

    /// The provider the core arms from, `nil` until one is set.
    var commissionedProvider: String?

    /// The ONE narrator's state, read through the parent that owns it.
    ///
    /// 🔴 NOT A `Narrator()` OF ITS OWN. A second narrator over the same
    /// persisted key is drift by construction: mute here, and the session's
    /// narrator keeps its stale `@Published` until relaunch — it would compile,
    /// render correctly, and lie. Same shape as the `@StateObject`-does-not-
    /// re-init defect from Arc B, in a new costume.
    var narrationOn: Bool

    var onToggleNarration: () -> Void

    /// The route sheet raised by `onOpenRoutes` is `RootView`'s; this one is
    /// the catalogue picker that used to live in NODES.
    @State private var routeSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                routingSection
                voiceSection
                Wordmark()
            }
            .padding(.bottom, 86)
        }
        .overlay {
            if routeSheet { routeSelectSheet }
        }
        .animation(.easeOut(duration: 0.28), value: routeSheet)
        // MOVED FROM `NodesView:193`. The catalogue is loaded by the screen
        // that renders it. `HomeView` is the other reader of the same store
        // (`RootView:583`) and still reads one source — only the load site
        // moved.
        .task { await routes.load() }
    }

    // MARK: - Routing

    private var routingSection: some View {
        VStack(spacing: 0) {
            sectionHeader("ROUTING", "WHERE THIS DEVICE SENDS ITS TURNS")
            VStack(spacing: 0) {
                // THE PROVIDER ROW. Distinct from Route below: that one picks
                // among the routes a GATEWAY offers, this one sets the
                // provider the CORE arms from. A phone with no gateway has
                // only this one.
                NodeRow(icon: "key.horizontal", label: "Provider",
                        value: providerRowValue) {
                    onOpenRoutes()
                }
                // No selection yet renders the gateway's own word for its
                // state, not an invented default.
                NodeRow(icon: "wifi", label: "Route",
                        value: routes.selected?.name ?? "TAP TO SELECT") {
                    routeSheet = true
                }
                // One label per arm, so the row says what the tap will DO
                // rather than what the app wishes were true. OUTSIDE any
                // per-arm conditional: "switchable anytime" is a product
                // ruling about reachability, and a row that exists only in
                // `.absent` hides the switch from the operator running
                // `.local`, who is exactly the one the ruling was made for.
                //
                // 🔴 `last: true` IS EARNED HERE. In NODES three consecutive
                // rows each claimed to be the last — a divider suppressed
                // three times where it was wanted twice. The flag MOVED with
                // the rows rather than being deleted: NODES's new terminal row
                // is Mnemosyne, and it now carries it.
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
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.r(0.18), lineWidth: Theme.hairline)
        )
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    // MARK: - Voice

    private var voiceSection: some View {
        VStack(spacing: 0) {
            sectionHeader("VOICE", "HEARD, THEN SPOKEN")
            VStack(spacing: 0) {
                NodeRow(icon: narrationOn ? "speaker.wave.2" : "speaker.slash",
                        label: "Spoken replies",
                        value: narrationOn ? "ON" : "MUTED",
                        last: true) {
                    onToggleNarration()
                    onToast(narrationOn ? "REPLIES MUTED" : "REPLIES SPOKEN")
                }
            }
            .padding(.vertical, 5)
        }
        .background(
            LinearGradient(colors: [Theme.r(0.07), Theme.w(0.02)],
                           startPoint: .init(x: 0.25, y: 0.0),
                           endPoint: .init(x: 0.75, y: 1.0))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.r(0.18), lineWidth: Theme.hairline)
        )
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Theme.display(11, .bold))
                .tracking(2.2)
                .foregroundStyle(Theme.text)
            Text(subtitle)
                .font(Theme.mono(9))
                .tracking(0.9)
                .foregroundStyle(Theme.r(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Row derivations

    private var providerRowValue: String {
        guard let id = commissionedProvider else { return "TAP TO SET" }
        return ProviderCatalog.label(for: id).uppercased()
    }

    private var gatewayRowLabel: String  { NodesView.gatewayRowLabel(for: resolution.config) }
    private var gatewayRowValue: String? { NodesView.gatewayRowValue(for: resolution.config) }

    // MARK: - Route select

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
                            .font(Theme.mono(9))
                            .tracking(0.9)
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
}
