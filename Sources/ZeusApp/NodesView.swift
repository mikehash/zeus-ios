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

    /// C1 — the MEMORY SEARCH field's text (`FIND A FILE` until `d5619c8`).
    @State private var findQuery: String = ""

    /// The query that was actually RUN, or `nil` if none has been.
    ///
    /// Not derived from `findQuery`: the field still holds its text after a
    /// zero-hit search, so the string cannot tell "typed but not submitted"
    /// from "submitted and empty-handed." Those render different summaries.
    @State private var findRan: String? = nil

    /// HELD, not recomputed. `search` is a blocking FFI call; a computed
    /// property would re-run the core on every render of this pane.
    @State private var findHits: [RecallHit] = []

    /// The index size AS READ ON THIS APPEARANCE, never a value carried in
    /// from a previous one. `inFlight` is what `READING` renders from: a
    /// stored `nil` cannot distinguish "no core" from "no answer yet", so the
    /// flag carries the distinction the Optional cannot.
    @State private var indexReading: (value: UInt32?, inFlight: Bool) = (nil, true)

    /// Why the index read failed, when it failed. Held separately from
    /// `indexReading.value` because a `nil` value already means `NO CORE`, and
    /// a gateway that raised is not a device without a core.
    @State private var indexError: String? = nil

    /// The generation of the search whose result may be written.
    ///
    /// Asserts the DROP, not the absence of change: a query superseded before
    /// its result lands must not overwrite the newer one, and a test that only
    /// checked "the hits changed" passes when the stale write wins a race.
    @State private var findGeneration: Int = 0

    @State private var findInFlight: Bool = false

    let onToast: (String) -> Void

    /// THE BREADCRUMB. Provider, Gateway and Route MOVED to SETTINGS at this
    /// commit; this row raises that tab and does nothing else.
    ///
    /// RAISE-ONLY, and that is the whole point. A mirrored row here would be a
    /// second write path over the same three preferences — the duplication
    /// hole Arc B closed by extracting `RoutePicker` rather than pasting a
    /// copy. The operator who met those rows in 192 still reaches them from
    /// where he left them, and there is still exactly one place they are set.
    var onOpenSettings: () -> Void

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
    var core: SessionCapabilities?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                mobileNode
                settingsBreadcrumb
                findPanel
                enrollButton
                Wordmark()
            }
            .padding(.bottom, 86)                          // :743 tab-bar gutter
        }
        // THE READ ON THIS APPEARANCE. The row shows `READING` until it lands
        // — never a size carried in from a previous appearance, which could
        // report a stale count for an index that has since been rebuilt.
        .task { await readIndexSize() }
        // :754-812 — the sheet layer, drawn OVER the scroll view rather than
        // inside it. Inside, the panel would scroll away with the content.
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
        Self.mnemosyneValue(indexSize: indexReading.value, reading: indexReading.inFlight)
    }

    /// Pure over the core's answer, so both the row and the toast are the same
    /// function of the same reading and cannot disagree.
    ///
    /// `nil` is NOT folded into the empty case. "No core to ask" and "a core
    /// that answered zero" are different facts, and the whole subject of this
    /// row is that an index with nothing in it must be distinguishable from a
    /// probe that never ran.
    /// `READING` is a FOURTH string, and it is distinct from both of the
    /// others for the same reason they are distinct from each other: "not
    /// asked yet" is neither "no core to ask" nor "a core that answered
    /// zero". It outranks the `nil` fold because during a read the `nil`
    /// means only that no answer has landed.
    static func mnemosyneValue(indexSize: UInt32?, reading: Bool = false) -> String {
        if reading { return "READING" }
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

    // MARK: - The settings breadcrumb

    /// Provider, Gateway and Route LEFT this pane at this commit. This row is
    /// the one thing that stayed: it raises the SETTINGS tab and writes
    /// nothing.
    ///
    /// 🔴 WHY A ROW AND NOT A MIRROR. The rows could have been rendered in both
    /// places. Two doors onto one write is the duplication hole Arc B closed —
    /// a pasted surface inherits none of the censuses anchored on the original,
    /// so a second Provider row could gate the model field on `.listed` or
    /// hardcode an id with every migrated leg still green. One canonical home,
    /// one breadcrumb, no second write path.
    private var settingsBreadcrumb: some View {
        VStack(spacing: 0) {
            NodeRow(icon: "slider.horizontal.3", label: "Provider, gateway & route",
                    value: "IN SETTINGS", last: true) {
                onOpenSettings()
            }
        }
        .padding(.vertical, 5)
        .background(
            LinearGradient(colors: [Theme.r(0.07), Theme.w(0.02)],
                           startPoint: .init(x: 0.25, y: 0.0),
                           endPoint: .init(x: 0.75, y: 1.0))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.r(0.18), lineWidth: Theme.hairline)
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
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
                // 🔴 `last: true` LANDED HERE, it was not deleted. Before this
                // commit three consecutive rows each passed it — Route,
                // Provider and Gateway — so the divider was suppressed three
                // times where it was wanted twice, and Mnemosyne, which is now
                // the pane's terminal row, passed nothing at all. The flag is a
                // position, so it MOVES with the rows rather than dying with
                // them: deleting the two dead ones and stopping would have left
                // NODES with no terminal row and SETTINGS with three.
                NodeRow(icon: "cylinder.split.1x2", label: "Mnemosyne",
                        value: mnemosyneValue, last: true) {
                    onToast(indexReading.inFlight
                            ? "READING"
                            : Self.mnemosyneToast(indexSize: indexReading.value))
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

    // MARK: - C1/B  memory search (the core's workspace index)

    /// The core's `search(query:)`, rendered under the name of what it
    /// actually searches — which CHANGED at `d5619c8`.
    ///
    /// ── Why the label says MEMORY now, and said FILE before ────────────
    ///
    /// At pin `2bfc08aa` the bridge built the index with
    /// `FileEntry::new(&rel, name, len)` and never called `with_first_line`
    /// or `with_tags` (call sites = 0, POS `index.add` = 1). `FileIndex`
    /// weights name 3.0, tags 2.0, first_line 1.0, so both lower tiers were
    /// structurally empty and every posting came from a FILE NAME — a fact
    /// written by REMEMBER lands inside `memory/MEMORY.md`, whose name does
    /// not change, and was unfindable here permanently. That is why C1
    /// shipped `FIND A FILE`.
    ///
    /// `d5619c8` landed both halves the honest label needs: content tokens
    /// into `with_tags` (bounded 64 KiB, NUL-rejected, de-duplicated) AND a
    /// re-index inside `remember`, so the fact is findable without a
    /// relaunch. `Recall.testTheLabelIsBackedByTheRust` reads the bridge
    /// source and reds if `with_tags` stops being called — the label cannot
    /// quietly become a lie again by a pin move.
    ///
    /// The results are HELD, not recomputed in the body: `search` is a
    /// blocking FFI call, and a computed property would re-run it on every
    /// render of every unrelated state change on this pane.
    private var findPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                iconWell("doc.text.magnifyingglass", tint: Theme.accent2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MEMORY SEARCH")
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
                Text("A word from a file, or a fact you remembered")
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
                        // PER-KIND. Three of this row's four slots were
                        // file-shaped: `icon` was the literal `"doc"`, `label`
                        // was `SearchHit.name` (a field the memory arm does
                        // not have), and the toast routed `path` through
                        // `dirLabel`. Only `value` survives kind-agnostic,
                        // because `score` is the one field on both wire arms.
                        //
                        // The switch is what makes the memory arm STRUCTURALLY
                        // incapable of reaching the doc glyph, the name slot,
                        // or `dirLabel` — a branch witnessed, which is stronger
                        // than a NEG asserting absence.
                        NodeRow(icon: pair.element.icon,
                                label: pair.element.label,
                                value: Recall.scoreLabel(pair.element.score),
                                last: pair.offset == findHits.count - 1) {
                            onToast(Self.hitToast(pair.element))
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
        findGeneration += 1
        let generation = findGeneration
        findRan = q
        findInFlight = true
        Task {
            // THE THROW IS LOAD-BEARING. A conformer that could not run the
            // query must not answer `[]` — that renders "we could not ask" as
            // "we asked and got nothing". The catch leaves `findHits` alone
            // and clears the in-flight flag, so the summary falls back to the
            // index sentence rather than reporting an empty result set.
            // The outcome is CARRIED to the one drop site, never acted on at
            // the point it lands. A second `mayWriteResult` call on the error
            // path would be a second drop site — and `RecallTests`'
            // definition-uniqueness leg reds on exactly that, correctly: a
            // guard that exists in two places is a guard that can be edited in
            // one of them.
            let outcome: Result<[RecallHit], Error>
            do {
                outcome = .success(try await core.search(query: q))
            } catch {
                outcome = .failure(error)
            }
            // THE DROP. A result from a superseded query is discarded, not
            // rendered — the operator's newest question is the only one whose
            // answer belongs on screen. A FAILED search is dropped on the same
            // test: a stale error message is as wrong as a stale result set.
            guard Recall.mayWriteResult(generation: generation, current: findGeneration) else { return }
            switch outcome {
            case let .success(hits):
                findHits = hits
            case let .failure(error):
                // `findHits` is LEFT ALONE, not cleared: a search that could
                // not run has not replaced the previous answer, and the
                // summary falls back to the index sentence rather than
                // reporting an empty result set.
                onToast("SEARCH FAILED — \(error)")
            }
            findInFlight = false
        }
    }

    /// The index read for THIS appearance.
    private func readIndexSize() async {
        indexReading = (nil, true)
        // `try?` folds a THROW into `nil`, which renders `NO CORE` — the
        // locality costume this commit exists to refuse. A gateway that could
        // not be read is reported as such; the row keeps `READING` off and
        // the toast carries the reason.
        let n: UInt32?
        do {
            n = try await core?.indexSize()
        } catch {
            indexReading = (nil, false)
            indexError = "\(error)"
            return
        }
        indexError = nil
        indexReading = (n, false)
    }

    /// What a tapped hit reports.
    ///
    /// `dirLabel` is reachable ONLY from the `.file` arm. Its `nil` means "at
    /// the workspace root" — a FILE fact, stated in its own doc comment
    /// (`Recall.swift:181`) — and a pathless Mnemosyne record routed through
    /// it would not render blank, it would render a claim about where it lives
    /// on disk. `WORKSPACE ROOT` stays a file label.
    static func hitToast(_ hit: RecallHit) -> String {
        switch hit.kind {
        case let .file(path, _):
            let name = hit.label
            return Recall.dirLabel(for: path).map { "\(name) — \($0)" }
                ?? "\(name) — WORKSPACE ROOT"
        case let .memory(_, memoryType, content):
            // The record's OWN fields. No path, no directory, no root.
            return Theme.joined([memoryType.uppercased(), content])
        }
    }

    private var findSummary: String {
        Recall.findSummary(query: findRan,
                           fileHits: findHits.filter(\.isFile).count,
                           indexSize: indexReading.value,
                           reading: indexReading.inFlight || findInFlight,
                           memoryHits: findHits.filter { !$0.isFile }.count,
                           aperture: Self.aperture(for: resolution.config))
    }

    /// WHICH measurement the FILES count came from — off the config arm, the
    /// same way the write-outcome string is chosen. Not a probe: the app
    /// already decided which backend it is asking.
    static func aperture(for config: GatewayConfig) -> Recall.Aperture {
        switch config {
        case .resolved:                     return .gateway
        case .absent, .malformed, .local:   return .embedded
        }
    }

    // MARK: - :735-741  enroll

    /// The label under a disabled ENROLL. Same author, same reason, and
    /// deliberately the same SENTENCE SHAPE as `HomeView.absentVerbLabel`:
    /// the absence is of a VERB, not of a link, so re-tapping cannot change
    /// it and no host is named.
    ///
    /// A static function rather than an inline literal so a test can assert
    /// the rendered string without a rendered view.
    static var absentEnrollmentLabel: String {
        Theme.joined(["ENROLL NODE", "NO ENROLLMENT TRANSPORT ON THIS BUILD"])
    }

    /// 🔴 TERMINALLY DISABLED, and it replaces a FABRICATION.
    ///
    /// This button toasted `NODE ENROLLMENT — SCAN THE NEW DEVICE` and then
    /// began nothing: no scanner, no pairing, no write. The sentence narrated
    /// a flow that does not exist in this build — the same class as the
    /// retired `MNEMOSYNE CONSISTENT` line, and worse than a dead button,
    /// because it instructed the operator to go do something.
    ///
    /// Disabled on VERB ABSENCE, exactly as BROADCAST/PING are: there is no
    /// enrollment transport here at all, so it is not conditioned on link
    /// state. Conditioning it on `resolution` would assert the verb exists
    /// and is merely unreachable.
    private var enrollButton: some View {
        VStack(spacing: 6) {
        Button {
            // Intentionally empty: `.disabled(true)` below means this never
            // runs. Empty rather than a toast, because any string here would
            // be a claim about an act that has no implementation.
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(Theme.display(14, .regular))
                Text("ENROLL NODE")
                    .font(Theme.display(9.5, .bold))
                    .tracking(1.9)                         // 0.2em at 9.5pt
            }
            .foregroundStyle(Theme.r(0.3))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(true)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(style: StrokeStyle(lineWidth: Theme.hairline, dash: [4, 4]))
                .foregroundStyle(Theme.r(0.2))
        )
        .accessibilityLabel(Self.absentEnrollmentLabel)

            // The reason, ON SCREEN. A greyed control with no sentence under
            // it reads as a bug; the sentence is what makes the disablement
            // honest rather than merely inert.
            Text(Self.absentEnrollmentLabel)
                .font(Theme.mono(8.5))
                .tracking(0.6)
                .foregroundStyle(Theme.w(0.4))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
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
