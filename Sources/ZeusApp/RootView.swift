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

    /// Background behaviour. Read here rather than in `ZeusApp` because the
    /// scene phase is only actionable where the observers live, and both of
    /// them — the link monitor and the session engine — are owned by this
    /// view.
    @Environment(\.scenePhase) private var scenePhase

    /// A deep-linked prompt awaiting the composer. Owned HERE and not in
    /// `SessionView` because the URL can arrive while a different tab is
    /// showing — the value has to outlive the tab switch that is about to
    /// happen. `SessionView` clears it once applied.
    @State private var pendingPrompt: String?

    /// The on-device recogniser. `@StateObject` because it owns an
    /// `AVAudioEngine` and a live tap — a `@State` value would be reconstructed
    /// on identity changes and leak the tap.
    @StateObject private var voice = VoiceInput()

    /// :433 — `showToast(text)` sets, then clears after 2800ms.
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    /// The gateway editor sheet. ONE flag and ONE capture of the arm, both
    /// owned here: the LINK pill and the NODES gateway row are two
    /// affordances for one sheet, and a per-tab flag would let both tabs
    /// believe their own editor was open.
    @State private var gatewayEditor = false
    @State private var gatewayEditorConfig: GatewayConfig? = nil

    /// The session loop. RootView READS the transcript and calls `send`; it
    /// cannot append a message or set an agent state, because neither is
    /// writable from here. The seed lives in the engine's initialiser.
    // The engine's factory is now supplied HERE, closing over the resolved
    // config, because the resolution seam needs a store and a property
    // initialiser has no store in scope. The comment that stood here argued
    // that a vanished call site cannot drift; true, and beside the point — the
    // vanished site was resolving from the environment alone, so it could
    // never produce `.local` at all.
    @StateObject private var session: SessionEngine

    /// Link state, MEASURED — the source `statusLine` did not have. The
    /// monitor resolves config once at construction and polls `/health`; both
    /// consuming sites read its verdict rather than a literal.
    @StateObject private var link: LinkMonitor

    /// The approval queue. Owned here, beside `link`, because the queue
    /// outlives any one render of HOME and a second owner would mean two
    /// pictures of one gateway's state.
    @StateObject private var approvals: ApprovalsStore

    /// The route catalogue. Built HERE and handed DOWN to `NodesView`, which
    /// used to own it as its own `@StateObject` — a view-scoped construction
    /// with no store in scope, and therefore permanently on the env-only half
    /// of resolution.
    @StateObject private var routes: RouteCatalogStore

    /// The gateway token store. Keychain in production, in-memory under
    /// `-zeusInMemoryTokens` — chosen at init from the launch-argument seam,
    /// the same switch the commission seed uses, so capture and test launches
    /// take the deterministic branch without a second construction site.
    private let tokens: GatewayTokenStoring

    /// The one credential provider. See `Credential.swift`.
    private let credentials: CredentialProviding

    /// The commission store this view was HANDED, RETAINED rather than used
    /// once and dropped. Until c1 it was consumed at `resolve` and discarded,
    /// so the editor had nothing to write through; now the sheet persists the
    /// URL through THIS instance. Retaining it is what makes the store
    /// identity assertable — the docstring below records the mutation that
    /// swapped it for a fresh `UserDefaultsCommissionStore()` with 294 tests
    /// green, and the leg that finally guards it reads this property.
    let store: CommissionStoring


    /// THE current configuration, shared by the engine, the monitor, the
    /// approvals queue and the route catalogue. `resolution` above is the
    /// LAUNCH one and is now read only by label surfaces; this is the live
    /// one. See `GatewayConfigSource`.
    @StateObject private var configSource: GatewayConfigSource

    /// Push state, owned by `ZeusApp` and passed in — NOT constructed here.
    /// A registrar built by this view would be replaced whenever the view is
    /// reconstructed, and a token delivered to the old one would be lost with
    /// no error anywhere.
    @ObservedObject var push: PushRegistrar

    /// EXTRACTED so the store-honouring write has a leg. Inlined in `init`
    /// it was structurally unguardable — a `View` initialiser is not callable
    /// from this test target, and the mutation that swapped `store` for a
    /// fresh `UserDefaultsCommissionStore()` left all 294 tests green: the
    /// resolution legs assert what `resolve` RETURNS, and said nothing about
    /// whether the caller passes the store it was handed. Fifth instance of
    /// the value-asserted / call-site-unguarded shape on this branch.
    ///
    /// The one line that calls it (`init`, above) remains guarded only by the
    /// source-cardinality leg — a `View` init is not observable in-process
    /// without ViewInspector. Smaller unguarded surface, not a closed one.
    /// The SessionView header, with the credential PROVENANCE appended.
    ///
    /// GATED ON `.linked` AND ONLY `.linked`. Appending ungated would put a
    /// provenance word on `LINKING…` and on `NO GATEWAY · SET
    /// ZEUS_GATEWAY_URL` — a claim about a credential for a config that has
    /// no endpoint to hold one. The word is composed HERE rather than inside
    /// `LinkState.statusLine` because `LinkState` is a pure function of
    /// REACHABILITY (`LinkMonitor.swift:30-50`) and the credential source is
    /// not a reachability fact; widening the enum to carry it would make
    /// every arm answerable for a property only one arm has.
    ///
    /// APERTURE, stated so its silence is never read as a miss: this is the
    /// SessionView header only. The NODES pill (`LinkState.badgeText`) and
    /// its subtitle stay TOPOLOGY-ONLY and carry no provenance by design.
    ///
    /// The word, never the bytes: `ENV` or `KEYCHAIN`, and nothing appended
    /// when the provider has no credential for the endpoint.
    static func statusLine(_ state: LinkState,
                           resolution: GatewayConfig.Resolution,
                           credentials: CredentialProviding) -> String {
        let base = state.statusLine
        guard case .linked = state,
              case .resolved(let endpoint) = resolution.config,
              let source = credentials.source(for: endpoint) else { return base }
        return "\(base) · \(source.rawValue)"
    }

    static func resolve(store: CommissionStoring) -> GatewayConfig.Resolution {
        GatewayConfig.resolve(from: ProcessInfo.processInfo.environment, store: store)
    }

    /// ARM, THEN RESOLVE, THEN COMPOSE — as one act, because a caller that
    /// remembers two of the three ships the defect this file was cut to fix.
    ///
    /// ## The incident
    ///
    /// `a06bbe4` composed the core's answer in `init` only. The SAVE
    /// re-resolve at `:262` called `RootView.resolve(store:)` bare, so the
    /// `.local` readiness arm silently reverted to `commission.provider == nil`
    /// — the disk-derived value the commit existed to retire — and
    /// `GatewayConfigSource.adopt` is the SOLE writer of `resolution`, so
    /// nothing downstream could notice. Composition-by-convention is exactly
    /// what `adopt`'s own doc comment refuses four `reconfigure(config:)`
    /// setters for.
    ///
    /// ## Two callers, ONE arming path
    ///
    /// `init` (first launch of the view) and the editor's `onSaved` re-resolve.
    /// They are two ENTRY POINTS to this one helper, NOT two arming paths: the
    /// census invariant is `setProvider(` production callers == 1, outside any
    /// `#if DEBUG`, reached only from `CoreArming.arm` below.
    ///
    /// ## Why there is no third caller
    ///
    /// "The commission gains a provider while the app is running" has no
    /// reachable trigger: `ZeusApp:82` renders `RootView` and
    /// `CommissioningView` as EXCLUSIVE arms of one `if let`, so finishing
    /// ROUTES swaps the arm and constructs a fresh `RootView` — this `init`
    /// runs again. `recordRoutesChoice` production callers = 2, and both are
    /// upstream of this helper. A third call site would be unreachable code.
    static func armedResolution(store: CommissionStoring) -> GatewayConfig.Resolution {
        let core = try? EmbeddedCore.shared.get()
        let seeded = LaunchArgs.seededProvider
        var commissionForArming = store.load()
        if let seeded {
            commissionForArming?.recordRoutesChoice(providerID: seeded.id,
                                                    model: seeded.model)
        }
        CoreArming.arm(commission: commissionForArming,
                       core: core,
                       providerKey: nil,
                       baseURL: seeded?.baseURL)
        return RootView.resolve(store: store)
            .withCoreReadiness(EmbeddedCoreArming(core: core))
    }

    /// `store` has NO DEFAULT, and neither does anything it feeds. Every
    /// observable below is constructed from ONE resolution, so the tabs cannot
    /// disagree about which gateway this app is talking to.
    init(store: CommissionStoring, push: PushRegistrar) {
        // THE SOLE PRODUCTION `setProvider` CALL, AND IT RUNS BEFORE THE
        // RESOLVE THAT MEASURES IT.
        //
        // Order is load-bearing: readiness is now the core's answer
        // (`hasProvider()`), so arming after the resolve would render
        // `NO PROVIDER` on a core that was armed one line later. This is the
        // first act of the view for that reason.
        //
        // Census invariant: `setProvider(` production callers == 1, reached
        // from here through `CoreArming.arm`, outside any `#if DEBUG`. The
        // DEBUG seam seeds the COMMISSION this call reads — it does not arm
        // the core itself, so the path a person launches is the path measured.
        let resolution = RootView.armedResolution(store: store)
        self.store = store
        self.push = push
        self.tokens = LaunchArgs.useInMemoryTokens
            ? InMemoryTokenStore()
            : GatewayTokenStore()
        // ONE provider instance for the whole view: the transport, the
        // approvals queue, the route catalogue and the editor's preflight all
        // read THIS object, so no two surfaces can disagree about what the
        // request carried. See `Credential.swift` for the precedence.
        let credentials: CredentialProviding = LaunchArgs.useInMemoryTokens
            ? StubCredentialProvider()
            : KeychainCredentialProvider()
        self.credentials = credentials
        // ONE source, four surfaces. The closure captures the SOURCE, not a
        // `GatewayConfig` copy — `SessionEngine` already calls this factory
        // per turn (`Session.swift:318`), so the freeze was never in the
        // engine, it was here: a `let config` captured four times meant a URL
        // saved mid-session was read at the next launch and not before.
        let source = GatewayConfigSource(resolution)
        _configSource = StateObject(wrappedValue: source)
        _session = StateObject(wrappedValue: SessionEngine(
            makeTransport: { box in
                Zeus.makeTransport(for: source.config, sessionID: box, credentials: credentials)
            }
        ))
        _link = StateObject(wrappedValue: LinkMonitor(source: source))
        _approvals = StateObject(wrappedValue: ApprovalsStore(source: source,
                                                             credentials: credentials))
        _routes = StateObject(wrappedValue: RouteCatalogStore(source: source,
                                                             credentials: credentials))
    }

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

            // The gateway editor, over both tabs. Same overlay layer as the
            // toast but a higher zIndex so an editor opened while a toast is
            // up draws above it — the editor is a decision, the toast is a
            // receipt, and the decision outranks it.
            if let config = gatewayEditorConfig, gatewayEditor {
                GatewayEditorSheet(config: config,
                                   resolution: configSource.resolution,
                                   tokens: tokens,
                                   store: store,
                                   isPresented: $gatewayEditor,
                                   credentials: credentials,
                                   onSaved: { configSource.adopt(RootView.armedResolution(store: store)) },
                                   onToast: showToast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(80)
            }
        }
        .animation(.easeOut(duration: 0.22), value: toast)
        .preferredColorScheme(.dark)
        // The transcript lands in the SAME single-shot binding a deep link
        // uses, and for the same reason: it is a fresh intent that must be
        // consumable exactly once. Reusing it also means the composer needs no
        // second ingestion path — one place text arrives, one place it clears.
        //
        // NEVER AUTO-SENDS. `VoiceTranscript.accepted` has already refused an
        // empty or whitespace-only result, so nothing here can dispatch an
        // utterance the operator did not make; what it cannot check is whether
        // the device heard them CORRECTLY, and that is what the review-then-tap
        // step is for.
        .onChange(of: voice.transcript) { _, new in
            guard let new, !new.isEmpty else { return }
            pendingPrompt = new
            voice.transcript = nil
            if tab != .session { tab = .session }
        }
        // `start()` is idempotent by design: `.task` re-fires on view identity
        // changes, and two poll loops would halve the effective interval with
        // nothing in the UI to show it.
        .task { link.start() }
        .task { await approvals.load() }
        // Background behaviour. Three phases, and only `.active` and
        // `.background` are acted on:
        //
        //   * `.background` — suspend. Polling stops (a `Task.sleep` loop in a
        //     suspended process is not paused, it is a wake the OS will
        //     eventually kill) AND the verdict is invalidated, because the
        //     rendered frame outlives the app's ability to re-measure it.
        //   * `.active`     — resume: probe now, then poll.
        //   * `.inactive`   — DELIBERATELY IGNORED. It fires for the app
        //     switcher, a system alert, a notification pull-down, and control
        //     centre — transient states the app returns from in under a
        //     second. Treating them as backgrounding would flap the pill to
        //     LINKING every time the user swiped down for a notification.
        // `zeus://` links. `onOpenURL` fires for cold start AND for a link
        // received while running, so this one modifier covers both — there is
        // no separate launch-options path to keep in step with it.
        //
        // A REFUSED link does nothing at all: no tab change, no toast, no
        // navigation. Falling back to a tab would put the user somewhere the
        // URL did not ask for and look like the link worked.
        .onOpenURL { url in
            switch DeepLink.parse(url) {
            case .tab(let t):
                tab = t
            case .session(let prompt):
                // Order matters: set the prompt BEFORE the tab switch. If the
                // tab changed first, `SessionView.onAppear` could run against
                // a still-nil binding and the prefill would be dropped on
                // exactly the cold-start path this is for.
                pendingPrompt = prompt
                tab = .session
            case nil:
                break
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: link.suspend()
            case .active:
                link.resume()
                // Permission can be revoked in Settings while the app is
                // backgrounded and the app is never told, so every foreground
                // re-reads it. Cheap, and the alternative is a badge that
                // reads ON for a build that can no longer receive anything.
                Task { await push.refresh() }
            case .inactive:   break
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .zeus:
            // NOT a placeholder any more. `LaunchArgs.initialTab` returns
            // `.zeus` unconditionally in release, so this is the cold-start
            // destination for every commissioned operator on every launch —
            // which is why it ships with restore rather than behind it.
            HomeView(link: link, session: session, push: push,
                     onOpenSession: { tab = .session },
                     onOpenGatewayEditor: { config in
                         gatewayEditorConfig = config
                         gatewayEditor = true
                     },
                     approvals: approvals,
                     resolution: configSource.resolution)
        case .session:
            SessionView(
                messages: session.messages,
                // :661 — the status line is a function of link topology.
                // It WAS the literal "LINKED · KITCHEN NODE", which read
                // LINKED with no gateway configured, none reachable, and none
                // answering. It is now the probe's verdict; the `remote`
                // ternary the prototype had is subsumed by `LinkState`.
                statusLine: Self.statusLine(link.state,
                                            resolution: configSource.resolution,
                                            credentials: credentials),
                state: session.state,
                // The gateway-named id, mirrored off the engine. The header
                // printed the literal "SESSION-01" while this value existed.
                sessionID: session.sessionLabel,
                prefill: $pendingPrompt,
                onSend: session.send,
                // :660 — voice hands control back to the ZEUS tab, then runs
                // the query. The tab switch is the part that is real here.
                // NO LONGER A TAB SWITCH. `:660`'s prototype hands control
                // back to ZEUS and then "runs the query"; the comment that
                // used to sit here admitted the tab switch was the only real
                // part and never said so to the OPERATOR — a silent
                // non-action, the shape retired at `NodesView:105`/`:191`.
                //
                // The mic now records on-device, and the transcript lands in
                // this composer. The tab does NOT change: the operator is
                // looking at the transcript they are about to add to, and
                // moving them away from it mid-utterance would hide the one
                // thing they need to check before sending.
                voiceState: voice.state,
                onVoice: voice.toggle,
                // Resolved HERE rather than inside the view, for the same
                // reason `voiceState` is: a `View` body cannot read the
                // environment, and a config read in a body would re-run on
                // every render. One read, one owner, rendered downstream.
                disarmReason: configSource.config.disarmReason
            )
        case .nodes:
            NodesView(link: link.state, routes: routes, onToast: showToast,
                      onOpenGatewayEditor: { config in
                          gatewayEditorConfig = config
                          gatewayEditor = true
                      },
                      resolution: configSource.resolution)
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
            Image(systemName: "checkmark").font(Theme.mono(12, .bold))
            Text(text)
                .font(Theme.mono(9.5))
                .tracking(1.14)
                .lineLimit(1)
                // A toast is transient and unrepeatable — a clipped one cannot
                // be re-read, so shrinking beats truncating here more than
                // anywhere else in the app.
                .minimumScaleFactor(0.7)
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
                            .font(Theme.display(17, .medium))
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
