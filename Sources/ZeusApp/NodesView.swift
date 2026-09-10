import SwiftUI

/// NODES tab — the fleet pane.
///
/// Transcribed from `817b19d3d:docs/prototypes/mobile/zeus/ZeusApp.jsx`
/// :667-742 (the `tab === 'nodes'` arm), with the shared `Row` helper at
/// :377-400 and `Badge` at :341-347.
///
/// ── (d): THE KITCHEN BLOCK IS RETIRED ───────────────────────────────────
/// This pane used to render a second node — `KITCHEN NODE`, a title, a
/// slogan, two `NodeSlider`s (volume/brightness), a mic toggle, and
/// `Ping node` / `Restart` / `Revoke access` — unconditionally, on every
/// install. It was a prototype fixture: nothing enrolled it, nothing could
/// reach it, and the sliders and toggle drove `@State` no transport read.
///
/// The record cannot replace it. `Commission.nodeEnrolled` is a `Bool` with
/// no identity — no name, no host, no list — so the true arm has nothing to
/// NAME. A pane that renders nothing when there are no nodes is honest; a
/// pane that renders a node nobody enrolled is not.
///
/// (f) FINISHED THE JOB: the Bool's last render — `1 node enrolled` in the
/// summary strip — is gone too. Nothing in a release build writes `true`
/// (the sole writer was the DEBUG capture seed), so that arm was unreachable
/// text describing an absent node. The strip reads `solo` until the record
/// carries a node list.
///
/// Retired with it, because the block was their only reachable caller:
/// `micToggle`, the revoke sheet + `confirmRevoke` + its overlay/animation,
/// `struct NodeSlider` (47 lines, zero remaining uses), the `muted` /
/// `volume` / `brightness` `@State`s, and the `link: LinkState` parameter —
/// every `nodeOnline` read lived inside the block. An unused parameter is
/// the `recordRoutesChoice` default one shape over: a hole a future caller
/// fills wrongly. A node LIST is a record change, phase-B+.
///
/// `ZeusApp.decommission()` survives and its doc still cites NODES → REVOKE
/// ACCESS as the wiring; that path is gone with the sheet and the function
/// is currently unraised. Left standing deliberately — decommissioning is a
/// real capability that needs a home, not a thing to delete because its
/// only button was a prototype's.
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

    /// `:410` — the route sheet. The revoke sheet that used to sit beside
    /// it was the kitchen block's only raiser and went with it in (d).
    @State private var routeSheet = false

    /// C1 — the FIND A FILE field's text.
    @State private var findQuery: String = ""

    /// The query that was actually RUN, or `nil` if none has been.
    ///
    /// Not derived from `findQuery`: the field still holds its text after a
    /// zero-hit search, so the string cannot tell "typed but not submitted"
    /// from "submitted and empty-handed." Those render different summaries.
    @State private var findRan: String? = nil

    /// HELD, not recomputed. `search` is a blocking FFI call; a computed
    /// property would re-run the core on every render of this pane.
    @State private var findHits: [SearchHit] = []

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

    /// The core handle this pane reads `index_size()` from.
    ///
    /// A PARAMETER, RETAINED — gate two of the pair (i) turned on. The value
    /// existing in the bridge is half; the view being able to REACH it is the
    /// other half, and this view held no handle at all. `RootView` gets one
    /// inside a static helper (`armedResolution`) and does not keep it, so a
    /// handle constructed here would be a SECOND core over the same workspace
    /// directory — the `InMemoryProviderKeyStore` fault, one subsystem over.
    /// It arrives from `EmbeddedCore.shared`, which is the process's one core.
    ///
    /// OPTIONAL, and the optional is load-bearing: `EmbeddedCore.shared` is a
    /// `Result`, and a core that failed to initialise is exactly the state
    /// where an invented `LIVE-LINK` would be most wrong. `nil` renders
    /// `NO CORE`, which is what happened.
    var core: ZeusCoreProtocol?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                mobileNode
                findPanel
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
        }
        .animation(.easeOut(duration: 0.28), value: routeSheet)
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

    /// The phone row's badge — the SAME derivation the HOME tile and the
    /// SESSION header pill read.
    ///
    /// Was `Badge(text: "ACTIVE", color: Theme.ok)`: a literal green `ok` over
    /// a core with no provider on it. `ProviderArming.swift`'s own header was
    /// written for that defect and it survived one file over, in a third
    /// consumer. There is no engine phase in scope here — this row is about
    /// the NODE, not a turn — so the phase argument is `.ambient` and the
    /// readiness half is the whole of what varies. `ReadinessBadge` collapses
    /// all four phases onto `UNARMED` when `disarmReason != nil`, so an
    /// unarmed core reads `UNARMED` regardless of what is passed here.
    private var nodeBadge: ReadinessBadge {
        ReadinessBadge.forState(.ambient,
                                disarmReason: resolution.config.disarmReason)
    }

    /// `N FILES INDEXED` / `INDEX EMPTY` / `NO CORE`.
    private var mnemosyneValue: String {
        Self.mnemosyneValue(indexSize: core?.indexSize())
    }

    /// Pure over the core's answer, so both the row and the toast are the same
    /// function of the same reading and cannot disagree.
    ///
    /// `nil` is NOT folded into the empty case. "No core to ask" and "a core
    /// that answered zero" are different facts, and the whole subject of this
    /// row is that an index with nothing in it must be distinguishable from a
    /// probe that never ran.
    static func mnemosyneValue(indexSize: UInt32?) -> String {
        guard let n = indexSize else { return "NO CORE" }
        return n == 0 ? "INDEX EMPTY" : "\(n) FILES INDEXED"
    }

    /// What the tap reports — a fresh reading, named as one.
    static func mnemosyneToast(indexSize: UInt32?) -> String {
        guard let n = indexSize else {
            return "MNEMOSYNE — NO CORE ON THIS DEVICE"
        }
        return n == 0
            ? "MNEMOSYNE — INDEX EMPTY"
            : "MNEMOSYNE — \(n) FILES INDEXED"
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
                    Text(CoreProvenance.nodeSubtitle())
                        .font(Theme.mono(9))
                        .tracking(0.9)
                        .foregroundStyle(Theme.r(0.7))
                }
                Spacer(minLength: 0)
                Badge(text: nodeBadge.text, color: nodeBadge.tint)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            VStack(spacing: 0) {
                // (h) — WAS `LIVE-LINK`, with a comment pinning it to "the same
                // missing `remote` source as SessionView's statusLine". That
                // comment was true of a REMOTE gateway and FALSE of the
                // embedded core, which exports `index_size` for exactly this
                // question — the bridge's own docstring calls it "a vacuity
                // probe, not a statistic": the only way to tell an empty index
                // from a no-match. Consumers in `Sources/` were 0.
                //
                // The tap USED to raise `MNEMOSYNE CONSISTENT — NO DELTA`: a
                // result reported for a check that never ran. That is a
                // fabrication rather than a stale label, so the tap now
                // re-reads and reports what it found — including the abstention
                // when there is no core to ask.
                NodeRow(icon: "cylinder.split.1x2", label: "Mnemosyne",
                        value: mnemosyneValue) {
                    onToast(Self.mnemosyneToast(indexSize: core?.indexSize()))
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

    // MARK: - C1  find a file (the core's file index)

    /// The core's `search(query:)`, rendered under the name of what it
    /// actually searches.
    ///
    /// ── Why the label says FILE and not MEMORY ──────────────────────────
    ///
    /// Walked at pin `2bfc08aa`: the bridge populates the index with
    /// `FileEntry::new(&rel, name, len)` and never calls `with_first_line` or
    /// `with_tags` (call sites = 0, POS `index.add` = 1). `FileIndex` weights
    /// name 3.0, tags 2.0, first_line 1.0 — so the lower two tiers are
    /// structurally empty and every posting came from a FILE NAME. A fact the
    /// operator writes with REMEMBER lands inside `memory/MEMORY.md`, whose
    /// NAME does not change, and is therefore unfindable here — permanently,
    /// not until relaunch. Calling this "memory search" would build a screen
    /// where you type the thing you just saved and get nothing.
    ///
    /// The results are HELD, not recomputed in the body: `search` is a
    /// blocking FFI call, and a computed property would re-run it on every
    /// render of every unrelated state change on this pane.
    private var findPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                iconWell("doc.text.magnifyingglass", tint: Theme.accent2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("FIND A FILE")
                        .font(Theme.display(11, .bold))
                        .tracking(2.2)
                        .foregroundStyle(Theme.text)
                    Text(findSummary)
                        .font(Theme.mono(9))
                        .tracking(0.9)
                        .foregroundStyle(Theme.r(0.7))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // 44pt is the touch-target floor and the field is free to grow
            // TALLER — the same measured decision as the session composer,
            // where pinning `height` clipped the caret line the user types on.
            TextField("", text: $findQuery, prompt:
                Text("File name")
                    .foregroundStyle(Theme.w(0.3))
            )
            .font(Theme.body(14))
            .foregroundStyle(Theme.text)
            .textFieldStyle(.plain)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit(runFind)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(Theme.w(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.w(0.08), lineWidth: Theme.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            // The field is DISABLED with no core rather than hidden: a field
            // that vanishes reports nothing, and `NO CORE` in the summary is
            // the fact the operator needs. Same rule the mnemosyne row runs.
            .disabled(core == nil)
            .opacity(core == nil ? 0.35 : 1)

            if !findHits.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(findHits.enumerated()), id: \.offset) { pair in
                        NodeRow(icon: "doc",
                                label: pair.element.name,
                                value: Recall.scoreLabel(pair.element.score),
                                last: pair.offset == findHits.count - 1) {
                            // The path is what the row cannot show and the
                            // operator cannot otherwise get: `name` is already
                            // rendered, so the tap reports the DIRECTORY.
                            onToast(Recall.dirLabel(for: pair.element.path)
                                        .map { "\(pair.element.name) — \($0)" }
                                        ?? "\(pair.element.name) — WORKSPACE ROOT")
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.vertical, 5)
            }
        }
        .padding(.bottom, 10)
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

    /// One reading, taken on submit.
    ///
    /// `findRan` is a SEPARATE `@State` from `findQuery` and that separation is
    /// the whole discrimination: the summary must distinguish "has not asked"
    /// from "asked and got nothing," and a query string alone cannot — the
    /// field still holds the text after a zero-hit search.
    private func runFind() {
        guard let q = Recall.queryToRun(from: findQuery) else {
            findRan = nil
            findHits = []
            return
        }
        guard let core else { return }
        findRan = q
        findHits = core.search(query: q)
    }

    private var findSummary: String {
        Recall.findSummary(query: findRan,
                           hitCount: findHits.count,
                           indexSize: core?.indexSize())
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
