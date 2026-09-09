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
    /// `fork` sits between `welcome` and `auth` because the deployment
    /// choice decides what AUTH even means — operator-on-this-phone vs.
    /// operator-against-that-gateway — and a question whose answer changes an
    /// earlier screen's meaning cannot come after it.
    ///
    /// Adding a member here is deliberately load-bearing: the rail denominator
    /// is `allCases.count`, `narration` is a `switch` with NO `default`, and
    /// `Backstep` is index-derived. The compiler names every site.
    case welcome, fork, auth, routes, nodes, callsign, done

    /// `NARRATION` at :305-312, verbatim including the typographic
    /// apostrophes — they are in the source and the TTS pronounces them
    /// identically, so changing them would be an unforced divergence.
    ///
    /// TAKES THE RECORD, not a computed property, because the `.done` arm
    /// branches on it. The two arms state RECORD facts only — "on your
    /// record", never "nominal" / "live" — because composed core readiness
    /// does not exist yet at this step: `CoreArming.arm` runs at
    /// `RootView:211` from `RootView.init`, and `RootView` is not constructed
    /// until `onComplete(commission)` (:740) hands this record away. A done
    /// headline that claimed a core verdict would be sourcing a fact the
    /// process has not computed — which is what `All systems nominal.`
    /// was doing: a provider with a bad key read "nominal" here and `REFUSED`
    /// one screen later. The core verdict lives on the session surfaces, where
    /// the core is.
    func narration(commission: Commission) -> String {
        switch self {
        case .welcome:
            return "Zeus core is live on this phone. Commissioning takes under a minute — let’s light it up."
        case .fork:
            return "Two ways to run me. On this phone, or against a core you already have."
        case .auth:
            return "First — you. Authenticate as operator."
        case .routes:
            // REWRITTEN because the previous line offered a *choice*, back
            // when MANAGED was the second card (:356). With one option there
            // is no pick, and the orb must not say there is on the step where
            // the operator is about to hand over a key.
            //
            // THE COMMENT MUST NOT QUOTE THE OLD LINE. `ManagedDeferralTests`
            // .testNoManagedCardStringSurvivesInTheShippingSource greps this
            // file for it; pasting it here as an explanation makes the grep
            // fail on a correct file — which is exactly what it did on the
            // first run of this cut. Same defect the auth branch warns about
            // at :339, committed within the hour of reading that warning.
            return "Now my brainstem. Give me a provider key and I reach the models direct."
        case .nodes:
            return "Any hardware to enroll? Scan a node — or skip. I run fine solo."
        case .callsign:
            return "Last thing. What do I call you on comms?"
        case .done:
            // Two arms, both record facts. The REPAIR is not in either
            // sentence — it is the `SET A PROVIDER` button at :759, which
            // returns to the step it names. A headline that also said "set
            // one in Routes" would be a repair instruction in a slot that
            // cannot act, beside a control that can.
            //
            // Bare form, no provider name interpolated: the summary strip
            // (:732) already renders it, and a variable-width headline is the
            // thing this screen is not doing at 390 pt.
            return commission.provider == nil
                ? "No provider on your record. I can't answer until one is set."
                : "Provider on your record. I arm on the next screen."
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

/// Backward navigation over the step order.
///
/// The prototype's entire implementation is one line — `ZeusCommissioning.jsx:389`,
/// a pure index decrement over `STEPS` (:303) — and it discards nothing. Ported
/// as a value type rather than as a method on the view so the two questions an
/// operator can actually see — *where does back go* and *what does it forget* —
/// are answerable without rendering anything.
///
/// NO HISTORY STACK, deliberately. A stack is emptied by `LaunchArgs.initialStep`
/// seeding a step directly, so the control would be absent in exactly the DEBUG
/// launches the capture script photographs: the store frames would disagree with
/// the shipped build about whether the affordance exists at all. Index-derived is
/// total over every entry, seeded or walked.
enum Backstep {

    /// :389. `nil` at index 0 — which is also the prototype's hidden case.
    static func previous(of step: CommissioningStep) -> CommissioningStep? {
        let all = CommissioningStep.allCases
        guard let i = all.firstIndex(of: step), i > 0 else { return nil }
        return all[i - 1]
    }

    /// :452 — `stepIdx > 0 && step !== 'done'`.
    ///
    /// HIDDEN, NOT UNMOUNTED. The rail is laid out against a fixed leading well;
    /// unmounting the button would re-centre the rail on two steps out of six, so
    /// the progress bar would change width for a reason that has nothing to do
    /// with progress. `done` is excluded even though index 4 has a predecessor —
    /// commissioning is finished there and the value has been produced.
    static func isAvailable(at step: CommissioningStep) -> Bool {
        step != .done && previous(of: step) != nil
    }

    /// The mutable state a backward entry carries. Grouped so the discard policy
    /// is one total function over the whole set rather than four assignments that
    /// can each be forgotten independently.
    struct Entry: Equatable {
        var commission: Commission
        var scanning: Bool
        var authed: Bool
    }

    /// What survives a backward entry into `target`, and what does not.
    ///
    /// PRESERVED: `commission.route` and `commission.callsign` — operator choices
    /// and typed input. `authed` — a completed verification. A state that vanishes
    /// when you step back is a surprise, and re-verifying is not free to a user
    /// whose passkey lives behind a biometric prompt.
    ///
    /// DISCARDED: `scanning`, pure label state (`SCAN NODE` → `SCANNING…`) that
    /// records nothing. And `commission.nodeEnrolled` on re-entering `.nodes`,
    /// because `false` there is not "no node" — it is *"I pressed SKIP"*, a
    /// recorded decision, and a step you have deliberately returned to must be
    /// re-askable. Discarding it on entry to `.nodes` only, so stepping back
    /// past that step does not quietly rewrite it.
    /// `.fork` is the SECOND member of the per-step re-ask rule, written into
    /// this same total function rather than as a second `if`: two independent
    /// conditionals over the same input are a policy in two places, and the
    /// next reader has to find both to know what stepping back forgets. One
    /// `switch` over the target is the policy, stated once.
    ///
    /// Stepping back to `.fork` discards `deployment` for the same reason
    /// `.nodes` discards `nodeEnrolled`: the stored value is not a fact about
    /// the world, it is *a decision the operator made*, and a step you have
    /// deliberately returned to must be re-askable rather than pre-answered.
    /// `gatewayURL` rides with it — a URL kept across a fork re-ask would be a
    /// REMOTE endpoint attached to a commission that now says LOCAL.
    static func entering(_ target: CommissioningStep, from state: Entry) -> Entry {
        var next = state
        next.scanning = false
        switch target {
        case .fork:
            next.commission.deployment = nil
            next.commission.gatewayURL = nil
        case .nodes:
            next.commission.nodeEnrolled = false
        case .welcome, .auth, .routes, .callsign, .done:
            break
        }
        return next
    }
}

/// What commissioning produces. The whole point of the flow is this value.
///
/// `Codable` is declared here rather than beside `CommissionStore` because
/// Swift synthesises `init(from:)` / `encode(to:)` only in the file that
/// declares the type; an extension elsewhere fails with two errors naming
/// synthesis, which point at the conformance and not at the file scope that
/// actually causes it.
///
/// The keys are hand-written so that renaming a property is a deliberate
/// decision about stored data rather than a refactor that silently
/// invalidates every persisted record.
struct Commission: Equatable, Codable {
    /// The route mode the operator chose.
    ///
    /// `managed` IS STILL HERE ON PURPOSE AND NO CODE PATH PRODUCES IT.
    /// The second routes card was removed at :356 — its title is deliberately
    /// NOT quoted here; `ManagedDeferralTests` greps this file for that string
    /// and an explanation containing it fails a correct file. Third time in
    /// one cut. (v1 is BYOK only;
    /// MANAGED awaits merakizzz's product decision on a hosted, credit-billed
    /// provider — `Provider::from_prefix` knows no such id and the bridge
    /// exports no billing surface, so the card was an affordance with no
    /// backing call). The CASE stays because `UserDefaultsCommissionStore.load`
    /// treats a decode failure as "no commission" and returns nil
    /// (CommissionStore.swift:78-84) — deleting it would make every install
    /// already holding `{"route":"managed"}` silently re-onboard. Tidiness is
    /// not worth a factory reset.
    enum Route: String, Codable { case managed, byok }

    /// Where the core the operator talks to actually runs.
    ///
    /// Optional at the property, not defaulted: `nil` means NO FORK SCREEN WAS
    /// EVER SHOWN — a record written before this key existed. It is not a
    /// third mode and nothing renders it as one; `GatewayConfig.resolve`
    /// folds it into `.local`, which is the behaviour those installs already
    /// had. The same reasoning as `provider`, one field over: an absent key
    /// must decode without erasing the record AND without fabricating a
    /// choice the operator never made.
    enum Deployment: String, Codable { case local, remote }

    /// ## Any key added after v1 is `decodeIfPresent` with NO fallback value
    ///
    /// Stated here rather than at each site because it is a property of the
    /// STORE, not of any one field: `UserDefaultsCommissionStore.load` turns a
    /// decode failure into "no commission" (CommissionStore.swift:78-84), so a
    /// plain `decode` of a key an older record lacks is a factory reset. And a
    /// `??` default is the opposite failure — the record survives and reports
    /// a value nobody wrote. Post-v1 keys: `provider`, `deployment`,
    /// `gatewayURL`.
    enum CodingKeys: String, CodingKey {
        case route
        case provider
        case callsign
        case nodeEnrolled = "node_enrolled"
        case deployment
        case gatewayURL = "gateway_url"
        case model
        case providerBaseURL = "provider_base_url"
    }

    init(route: Route = .byok,
         provider: String? = nil,
         callsign: String = "",
         nodeEnrolled: Bool = false,
         deployment: Deployment? = nil,
         gatewayURL: String? = nil,
         model: String? = nil,
         providerBaseURL: String? = nil) {
        self.route = route
        self.provider = provider
        self.callsign = callsign
        self.nodeEnrolled = nodeEnrolled
        self.deployment = deployment
        self.gatewayURL = gatewayURL
        self.model = model
        self.providerBaseURL = providerBaseURL
    }

    /// HAND-WRITTEN BECAUSE ADDING A FIELD IS A MIGRATION.
    ///
    /// Swift's synthesised `init(from:)` does NOT fall back to a property's
    /// default value for a missing key — it throws `keyNotFound`, which
    /// `CommissionStore.load` turns into nil, which re-onboards the operator.
    /// So every record written before `provider` existed would have been
    /// erased by the synthesised decoder: the same defect as deleting the
    /// `managed` case, arriving through the opposite edit. `decodeIfPresent`
    /// on the NEW key is the migration.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        route = try c.decode(Route.self, forKey: .route)
        // NO nil-coalesce to a provider literal here. (The forbidden shape is
        // deliberately NOT spelled out: a comment that quotes the string a
        // guard greps for is itself a hit, and this file has already tripped
        // that three times tonight. Cite the shape, not the string.)
        // A record written before this key existed did not hold a provider,
        // and defaulting one here would print a provider the operator never
        // chose onto the completion screen — the fabricated route-count class
        // of `Commission.summary`, one field over. Absent decodes to absent.
        // This file now names NO provider at all: the ROUTES step renders
        // the core's own catalog and persists the id the operator tapped, so
        // the only literal that ever reaches `provider` came from
        // `list_providers()`. The guard on this is a count of ZERO in
        // shipping source, not a count of one.
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        callsign = try c.decode(String.self, forKey: .callsign)
        nodeEnrolled = try c.decode(Bool.self, forKey: .nodeEnrolled)
        deployment = try c.decodeIfPresent(Deployment.self, forKey: .deployment)
        gatewayURL = try c.decodeIfPresent(String.self, forKey: .gatewayURL)
        // Same migration shape as `provider`: a record written before this key
        // existed did not hold a model, and `decode` would throw keyNotFound →
        // CommissionStore.load returns nil → the operator re-onboards.
        model = try c.decodeIfPresent(String.self, forKey: .model)
        providerBaseURL = try c.decodeIfPresent(String.self, forKey: .providerBaseURL)
    }

    var route: Route = .byok
    /// The provider id the routes step collected, lowercased. Fed to the
    /// bridge's `setProvider` → `Provider::from_prefix` (zeus-core:8922);
    /// there is deliberately no provider table on the Swift side, so this is
    /// a string the CORE validates and not an enum this app invents.
    var provider: String?
    var callsign: String = ""
    var nodeEnrolled: Bool = false

    /// `nil` = no fork screen was shown for this record. See `Deployment`.
    var deployment: Deployment?

    /// The REMOTE endpoint, as the operator typed it. Stored RAW, unvalidated:
    /// `GatewayConfig.parseEndpoint` is the only parser, and pre-validating
    /// here would be the second one this cut exists to prevent.
    var gatewayURL: String?

    /// The model ROUTES obtained FROM THE PROVIDER, never a literal.
    ///
    /// `nil` means the provider answered no listing — v1's `list_models` is
    /// Ollama-only, so a keyed provider legitimately has none and
    /// `CoreArming.arm` names that state rather than inventing a model name.
    /// A hardcoded default here would be a claim about someone else's
    /// catalogue with no reader to catch it going stale.
    var model: String?

    /// WHERE THE `url`-SHAPE PROVIDER LIVES, as the operator typed it.
    ///
    /// SEPARATE FROM `gatewayURL` ON PURPOSE. That field is the REMOTE arm's
    /// endpoint — `GatewayConfig.resolve` reads it to decide what transport
    /// this app talks over, and `recordDeployment` nils it on a LOCAL fork.
    /// Writing an Ollama daemon URL there would make a LOCAL install
    /// indistinguishable from a REMOTE gateway config one layer up: two
    /// subjects sharing a spelling, which is the fault class this codebase has
    /// already paid for three times.
    ///
    /// `nil` means the operator has not given one. It is NOT defaulted to
    /// `http://localhost:11434`: on the simulator localhost is the Mac and the
    /// default happens to work, on a phone localhost is the phone and the
    /// route can never reach the operator's rig. The bridge's own
    /// `OLLAMA_DEFAULT_URL` fallback stays — it is the core's business — but
    /// this app must never reach it, so a `.url` provider is armed with a
    /// value or refuses to arm.
    var providerBaseURL: String?

    /// The `done` summary line.
    ///
    /// IT PRINTS ONLY VALUES SOMETHING WROTE. The prototype's
    /// `11 routes · managed` (ZeusCommissioning.jsx, done step) was a route
    /// count nothing measured — a fabricated number on the completion screen,
    /// the same class as a latency on a pill no probe produced. What replaces
    /// it is the provider the operator actually set at the routes step,
    /// rendered through the CORE'S OWN LABEL and nothing else. Not
    /// `id.uppercased()`: that was Swift inventing a display form for a value
    /// it does not own (`xiaomimimo` → `XIAOMIMIMO`), which is what
    /// `ProviderInfo.label` exists to prevent.
    /// EXTRACTED BECAUSE THE VIEW BODY IS NOT OBSERVABLE IN THIS TARGET.
    /// Deleting the write inside the CTA closure left all 283 tests green
    /// (measured) — the third instance today of value-asserted /
    /// call-site-unguarded. The decision now lives in a function with its own
    /// leg; the one line that calls it is guarded only by the source grep in
    /// `CommissionStoreTests`, which is a weaker instrument, stated as such.
    /// The sole writer of `deployment` from the fork screen.
    ///
    /// Same shape and same reason as `recordRoutesChoice` below: a mutation
    /// that lives only inside a SwiftUI CTA closure is unreachable from any
    /// in-process test, so deleting it costs nothing measurable and every leg
    /// stays green. Named, it has a call site a guard can count.
    mutating func recordDeployment(_ choice: Deployment) {
        deployment = choice
        // Choosing LOCAL erases any endpoint a previous REMOTE pass wrote. A
        // stale URL on a LOCAL commission is not inert: it is the value the
        // editor seeds and the value a later REMOTE switch would silently
        // adopt without the operator re-typing it.
        if choice == .local { gatewayURL = nil }
    }

    /// The sole writer of `gatewayURL`, and the third of this shape beside
    /// `recordDeployment` above and `recordRoutesChoice` below. Same reason:
    /// a mutation that lives only inside a SwiftUI SAVE closure is
    /// unreachable from any in-process test, so deleting it costs nothing
    /// measurable and every leg stays green. Named, it has a call site a
    /// census can count.
    ///
    /// NORMALISES ABSENCE TO `nil`. An empty or whitespace-only field is the
    /// operator clearing the endpoint, not the operator setting it to "";
    /// `GatewayConfig.resolve` reads the commission arm as a URL string and
    /// `""` there is `malformed`, which would render GATEWAY URL INVALID —
    /// FIX IT for a field he deliberately emptied.
    mutating func recordGatewayURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        gatewayURL = trimmed.isEmpty ? nil : trimmed
    }

    /// THE STEP WRITES BOTH THE PROVIDER AND THE MODEL.
    ///
    /// `model` has NO default: the caller must have asked the provider. Passing
    /// nil is representable and means "the provider listed nothing", which is a
    /// state `CoreArming.arm` renders — it is not the same as a model the app
    /// chose.
    mutating func recordRoutesChoice(providerID: String,
                                     model chosenModel: String?,
                                     baseURL rawBaseURL: String?) {
        route = .byok
        provider = providerID
        model = chosenModel
        // Normalised to nil the same way `recordGatewayURL` normalises its
        // own: an empty string is a URL the core will accept and then fail on
        // at the wire, which reports as a provider error instead of as the
        // missing field it is.
        let trimmed = rawBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        providerBaseURL = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    var summary: String {
        // nil is a real state, not a missing value to paper over: a legacy
        // record never held a provider, and the screen says so rather than
        // naming one the operator did not choose.
        let routeText = provider.map { Theme.joined([ProviderCatalog.label(for: $0), "OWN KEY"]) } ?? "no provider"
        // (f): `solo` UNCONDITIONALLY, and the Bool is not consulted.
        //
        // Measured at c525c937: `nodeEnrolled = true` has ZERO writers in
        // `Sources/` outside `LaunchArgs.captureSeed` (`#if DEBUG`). The
        // `SCAN NODE` button at the nodes step writes `scanning`, a label
        // state, and nothing else; `SKIP — RUN SOLO` and the backstep rule
        // both write `false`. So in a release build the true arm of this
        // ternary was UNREACHABLE — `1 node enrolled` could only ever appear
        // under a capture flag, on a screenshot, describing a node that does
        // not exist. That is the prototype's `11 routes · managed` in a
        // different costume: a count nothing measured.
        //
        // The Bool survives on the record — it decodes, it persists, and a
        // node LIST is the phase-B+ record change that will give it identity
        // — but it has no RENDER until something can name what it counts.
        let nodeText = "solo"
        let operatorText = callsign.isEmpty ? "operator" : "operator \(callsign.lowercased())"
        return Theme.joined(["zeus core", routeText, nodeText, operatorText])
    }
}

// MARK: - Host

struct CommissioningView: View {
    /// Called once, on leaving `done`. The parent owns what happens next.
    let onComplete: (Commission) -> Void

    /// Where a typed provider key lands. NO DEFAULT, for the reason every
    /// other seam on this flow has none: a default lets a future call site
    /// omit the store and write the operator's secret into a stand-in that
    /// forgets it, which reads as "the key did not save" one screen later.
    let keys: ProviderKeyStoring

    @StateObject private var narrator = Narrator()
    /// Seeded from `-zeusStep` in DEBUG only; `.welcome` otherwise.
    @State private var step: CommissioningStep = LaunchArgs.initialStep
    @State private var commission = Commission()
    @State private var authed = false

    /// The fork card the operator has TAPPED, held in the view and nowhere else.
    ///
    /// This exists because the tap had been writing `commission.deployment`
    /// directly, which made "highlighted" and "chose" the same state in the
    /// stored record and left a REMOTE tap behind after backing out. A
    /// preselection is view state by nature: it is what the screen is showing,
    /// not what the flow has produced.
    @State private var forkPick: Commission.Deployment? = nil

    /// What the fork screen HIGHLIGHTS, which is not what the record holds.
    ///
    /// LOCAL is the default rendering because it is the option that needs
    /// nothing from the operator — but `commission.deployment` stays nil until
    /// CONTINUE writes it. Deriving the highlight instead of seeding the field
    /// keeps "shown a preselection" and "made a choice" distinguishable in the
    /// stored record, which is the same distinction `provider: String?` buys
    /// one field over.
    private var forkSelection: Commission.Deployment {
        forkPick ?? commission.deployment ?? .local
    }
    @State private var scanning = false

    /// The provider row the operator has TAPPED, held in the view.
    ///
    /// Same shape as `forkPick` one field over: a preselection is what the
    /// screen is showing, not what the flow produced. `commission.provider`
    /// stays nil until CONTINUE writes it, so "was shown a list" and "chose"
    /// remain distinguishable in the stored record.
    @State private var providerPick: String? = nil

    /// The model the operator TYPED. Required for every shape.
    ///
    /// There is no default literal and no guess. `list_models` is Ollama-only
    /// by construction (`lib.rs:236` returns `Unsupported` for every other
    /// prefix), so a picker that relied on `firstModel` would leave 21 of 26
    /// providers unable ever to arm — `NO MODEL — <label> LISTED NONE` on
    /// every install. The field is the collectable half; the KEY field beside
    /// it is not collectable until the provider-scoped keychain lands, and the
    /// screen shows those as two states rather than averaging them into one.
    @State private var modelText: String = ""

    /// The key the operator is typing, held in the view and NEVER in the
    /// record. `Commission` rides in `UserDefaults` precisely because it
    /// carries no secret (`CommissionStore.swift` docstring); this string is
    /// written to the Keychain by CONTINUE and to nothing else.
    @State private var keyText: String = ""
    /// The `url`-shape provider's endpoint. Empty is a real state: the CTA
    /// refuses it rather than substituting a default.
    @State private var baseURLText: String = ""

    /// Set once per appearance of ROUTES, from the core's own catalog.
    @State private var providerRows: [ProviderRow] = []

    /// The search text. VIEW STATE ONLY — never written to the record and
    /// never cleared by a tap, so a search that produced a choice still shows
    /// what was searched for; the operator can see WHY the list is short.
    @State private var providerQuery: String = ""

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
        .onAppear {
            // Mute BEFORE the first narrate, not after: `voiceOn`'s didSet
            // stops an in-flight utterance, so muting second would still
            // let the orb enter `.speaking` for a frame the shutter can see.
            if LaunchArgs.muteVoice { narrator.voiceOn = false }
            narrator.narrate(step.narration(commission: commission))
        }
        .onChange(of: step) { _, new in narrator.narrate(new.narration(commission: commission)) }
        .onDisappear { narrator.stop() }
    }

    private var orbMode: DeviceOrb.Mode {
        narrator.isNarrating ? .speaking : step.idleOrbMode
    }

    // MARK: Chrome

    /// Progress rail + voice toggle. :455-465.
    private var header: some View {
        HStack(spacing: 10) {
            // A LEADING WELL THAT IS ALWAYS THERE. `.hidden()` keeps the frame
            // and drops the hit test, so the rail's width is one number for all
            // six steps instead of two. See `Backstep.isAvailable`.
            Button { goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.w(0.6))
                    // A TAP TARGET — floor is Theme.controlSize (44), not the 34
                    // the prototype drew (:449), same rule as the voice toggle.
                    .frame(minWidth: Theme.controlSize, minHeight: Theme.controlSize)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Theme.w(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(Theme.r(0.2), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .opacity(Backstep.isAvailable(at: step) ? 1 : 0)
            .disabled(!Backstep.isAvailable(at: step))
            .accessibilityHidden(!Backstep.isAvailable(at: step))

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
                    .font(Theme.body(15))
                    .foregroundStyle(narrator.voiceOn ? Theme.accent2 : Theme.w(0.4))
                    // A TAP TARGET, so the floor is Theme.controlSize (44), not the
                    // 34 this well was drawn at. 44 is the floor for things you touch;
                    // a decorative well takes its own size as the floor instead
                    // (see NodesView.iconWell, which stays at 38 for that reason).
                    .frame(minWidth: Theme.controlSize, minHeight: Theme.controlSize)
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
            PrimaryButton("INITIALIZE", glyph: "arrow.right") { step = .fork }

        case .fork:
            VStack(alignment: .leading, spacing: 10) {
                // Preselection is RENDERED, never stored: the taps below
                // write `forkPick`, which is view state, and CONTINUE is the
                // only line that touches the record. "The operator looked at a
                // screen where LOCAL was highlighted" and "the operator chose
                // LOCAL" stay different states.
                //
                // This comment previously asserted that while the two closures
                // beneath it assigned the record field directly. It was not
                // caught by the census leg because that leg counts the WRITER's
                // NAME, not the FIELD's ASSIGNMENTS — so the guard below now
                // counts assignments to `deployment` in this file, which is the
                // needle the claim is actually about.
                RouteCard(
                    title: "LOCAL — THIS PHONE",
                    copy: "The core runs in-process. No gateway hop — your key goes straight to the provider from this phone.",
                    selected: forkSelection == .local
                ) { forkPick = .local }

                RouteCard(
                    title: "REMOTE — EXISTING GATEWAY",
                    copy: "Point this phone at a Zeus gateway you already run.",
                    selected: forkSelection == .remote
                ) { forkPick = .remote }

                Text("SWITCHABLE ANYTIME IN NODES → LINK")
                    .font(Theme.mono(8.5))
                    .tracking(1.4)
                    .foregroundStyle(Theme.w(0.3))

                PrimaryButton("CONTINUE", glyph: "arrow.right") {
                    // The SOLE writer of the preselected value. Extracted to a
                    // named mutating func rather than left as a closure body
                    // because a write that lives only inside a CTA closure is
                    // the call-site-unguarded shape this branch has now paid
                    // for five times: the value is asserted, the site that
                    // produces it is deletable with every test still green.
                    commission.recordDeployment(forkSelection)
                    step = .auth
                }
            }

        case .auth:
            if authed {
                // Two children now, so an explicit stack: a bare TupleView in a
                // ViewBuilder branch has no layout of its own and would inherit
                // whatever the caller happens to be.
                VStack(spacing: 12) {
                // Replaced in place — no modal, no page change (:509-515).
                HStack(spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(Theme.mono(16, .heavy))
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

                // THE VERIFIED BRANCH NOW HAS A CTA, and the defect it fixes is
                // older than back-nav: before this, `authed == true` rendered a
                // badge and nothing else, and the branch's only forward writer
                // lived in `doAuth` (see below) behind a 1.2s timer reachable
                // solely from the `else` arm's two buttons. Any entry here that
                // did not come through that timer was a dead end: backward from
                // the next step, and `LaunchArgs.initialStep` seeding this one
                // while already verified. Fixed at the branch, not at the entry,
                // because the defect is "this rendering has no forward
                // affordance" and it bites every way in.
                //
                // THE COMMENT MUST NOT QUOTE THE WRITER. `BackstepTests`
                // .testVerifiedAuthBranchHasAForwardWriterInShippingSource
                // greps this slice for that assignment; spelling it out in prose
                // here makes the guard pass on a branch with the button deleted.
                // Fourth time tonight an explanation matched the needle meant
                // for the code — cite the coordinate, never the string.
                PrimaryButton("CONTINUE", glyph: "arrow.right") { step = .routes }
                }
            } else {
                VStack(spacing: 0) {
                    PrimaryButton("CONTINUE WITH PASSKEY", glyph: "touchid", action: doAuth)
                    QuietButton("USE NOVAXAI ID", action: doAuth)
                }
            }

        case .routes:
            routesStep


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

                // THE REPAIR ACTS IN ITS OWN SLOT. A label naming a fix the
                // reader cannot perform from where they are standing is the
                // defect this app retires elsewhere (`no provider` in the
                // footer says the state and nothing else). Here the slot CAN
                // act: the tap returns to `.routes`, which is the step that
                // sets the provider, so the words and the effect are the
                // same thing.
                //
                // Branches on the RECORD (`provider == nil`), NOT on composed
                // readiness — and that is not the proxy defect ② retired,
                // because this control makes no readiness claim. The core is
                // not armed at this step (`CoreArming.arm` has one production
                // caller, `RootView:211`, reached only after `onComplete`
                // hands the record over at :740), so a readiness fact does
                // not exist anywhere in the process yet. "No provider on the
                // record" is a fact this screen owns.
                if commission.provider == nil {
                    QuietButton("SET A PROVIDER") { step = .routes }
                }
            }
        }
    }

    /// :371-375 — auth resolves, the block swaps in place, then the flow
    /// advances after 1.2s. The delay is deliberate: the operator is meant
    /// to read the verified line, so it is not a spinner artefact.
    /// The only writer of a backward transition. :389, plus the discard policy
    /// the prototype does not have because the prototype has no state to lose.
    private func goBack() {
        guard let target = Backstep.previous(of: step) else { return }
        let next = Backstep.entering(
            target, from: .init(commission: commission, scanning: scanning, authed: authed)
        )
        commission = next.commission
        scanning = next.scanning
        authed = next.authed
        // The rendered preselection is view state, so `Backstep.entering` —
        // which is a total function over the RECORD — cannot reach it. Cleared
        // here at the same site, or a discarded choice stays highlighted.
        if target == .fork { forkPick = nil }
        withAnimation { step = target }
    }

    private func doAuth() {
        withAnimation { authed = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            step = .routes
        }
    }

    /// ROUTES: THE CORE'S CATALOG, THE OPERATOR'S CHOICE.
    ///
    /// Before this cut the step rendered ONE card with a hardcoded id and
    /// upper-cased it for display. Rows now come from `list_providers()`, the
    /// LABEL is rendered and the ID is persisted, and the model is typed
    /// because no catalog can supply it for a keyed provider in v1.
    ///
    /// The KEY field is DISABLED WITH ITS REASON rather than absent: a
    /// provider whose shape says `Key` genuinely needs one, and a screen that
    /// simply omitted the field would be silent about a requirement the arm
    /// message (`NO KEY FOR <label> — ENTER ONE IN ROUTES`) points right back
    /// at. Disabled-with-reason is this app's established form for a state
    /// that is real but not yet actionable — the same register as `UNSET`.
    @ViewBuilder
    private var routesStep: some View {
        let selected = providerPick.flatMap { id in providerRows.first { $0.id == id } }

        VStack(spacing: 10) {
            // SEARCH-FIRST: the field sits ABOVE the list because 26 rows
            // is past the point where scanning beats typing, and a search box
            // discovered after scrolling has already failed its purpose.
            TextField("", text: $providerQuery, prompt:
                Text("SEARCH PROVIDERS").font(Theme.mono(12)).foregroundStyle(Theme.w(0.2))
            )
            .font(Theme.mono(13))
            .foregroundStyle(Theme.text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(Theme.w(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .stroke(Theme.w(0.10), lineWidth: 1)
                    )
            )
            .accessibilityLabel("Search providers")

            ScrollView {
                VStack(spacing: 8) {
                    let groups = ProviderCatalog.grouped(providerRows, query: providerQuery)
                    // A QUERY THAT MATCHES NOTHING SAYS SO. An empty scroll
                    // view and a list still loading are the same pixels; the
                    // needle is echoed back so the operator can see what was
                    // actually searched for.
                    if groups.isEmpty && !providerRows.isEmpty {
                        Text("NO PROVIDER MATCHES \"\(providerQuery.uppercased())\"")
                            .font(Theme.mono(9))
                            .tracking(1.0)
                            .foregroundStyle(Theme.w(0.35))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    ForEach(groups, id: \.kind) { group in
                        Text(group.kind.header)
                            .font(Theme.mono(8.5))
                            .tracking(1.2)
                            .foregroundStyle(Theme.w(0.3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    ForEach(group.rows, id: \.id) { row in
                        RouteCard(
                            title: row.label,
                            copy: row.shape.rowCopy,
                            selected: row.id == providerPick
                        ) {
                            // A key typed for one provider is not a key for
                            // another: switching rows clears the field, and the
                            // OLD provider's stored key is removed so a
                            // half-finished choice leaves no orphan secret.
                            if let previous = providerPick, previous != row.id {
                                keyText = ""
                                baseURLText = ""
                                keys.removeProviderKey(for: previous)
                            }
                            providerPick = row.id
                            commission.route = .byok
                            // THE PROBE GETS THE SAME URL THE ARM WILL.
                            // `list_models` is Ollama-only in v1, so this is
                            // the one call that reaches a `.url` provider —
                            // passing nil here sends it to the bridge's
                            // localhost fallback, which on a phone is the
                            // phone, and the row then reads
                            // `Ollama LISTED NONE` for a rig answering fine.
                            let typedURL = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                            modelText = CoreArming.firstModel(
                                for: row.id,
                                core: try? EmbeddedCore.shared.get(),
                                key: nil,
                                baseURL: typedURL.isEmpty ? nil : typedURL) ?? ""
                        }
                    }
                    }
                }
            }
            .frame(maxHeight: 260)

            if let selected {
                TextField("", text: $modelText, prompt:
                    Text("MODEL").font(Theme.mono(12)).foregroundStyle(Theme.w(0.2))
                )
                .font(Theme.mono(13))
                .foregroundStyle(Theme.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .fill(Theme.w(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.corner)
                                .stroke(Theme.w(0.10), lineWidth: 1)
                        )
                )
                .accessibilityLabel("Model for \(selected.label)")

                if case .key = selected.shape {
                    keyField(for: selected)
                }
                if case .url = selected.shape {
                    baseURLField(for: selected)
                }
                if case let .unsupported(reason) = selected.shape {
                    Text("\(selected.label.uppercased()) CANNOT BE SET FROM THIS SCREEN — \(reason.uppercased())")
                        .font(Theme.mono(8.5))
                        .tracking(1.0)
                        .foregroundStyle(Theme.w(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            do {
                // The hint is part of the contract: the key field here is
                // not the only place keys can be added.
                Text("MORE ROUTES ANYTIME IN NODES → ROUTE")
                    .font(Theme.mono(8.5))
                    .tracking(1.0)
                    .foregroundStyle(Theme.w(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            // The CTA is disabled until BOTH halves are answered, because the
            // record it writes has no representable "partly chosen" state.
            PrimaryButton("VALIDATE + CONTINUE", glyph: "arrow.right") {
                guard let id = providerPick else { return }
                let typed = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !typed.isEmpty else { return }
                // THE STEP WRITES THE PROVIDER AND THE MODEL, both from the
                // operator. `Commission.provider` is `String?` and nil means
                // nobody chose; nothing in this file names a provider now.
                commission.recordRoutesChoice(providerID: id,
                                              model: typed,
                                              baseURL: baseURLText)
                // THE SECRET GOES TO THE KEYCHAIN, NOT TO THE RECORD. The
                // write is here and only here, after the record write, so a
                // key can never be stored for a provider the flow did not
                // commit to.
                let secret = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !secret.isEmpty { keys.setProviderKey(secret, for: id) }
                step = .nodes
            }
            .disabled(!Self.routesCTAEnabled(providerPick: providerPick,
                                             modelText: modelText,
                                             shape: selected?.shape,
                                             baseURLText: baseURLText))
        }
        .onAppear {
            providerRows = ProviderCatalog.current.rows()
            // CAPTURE SEAM. Writes the same two `@State` fields a tap and a
            // keystroke write, and nothing else — no record write, no key.
            // Inert unless `-zeusPick` is passed, and `LaunchArgs.pickedRoute`
            // is `nil` in release, so this is a no-op in a shipped build.
            //
            // Guarded on `providerPick == nil` so a re-appearance of ROUTES
            // (backstep, then forward again) cannot stomp a choice the
            // operator has since made by hand.
            if providerPick == nil, let seed = LaunchArgs.pickedRoute {
                providerPick = seed.id
                if let m = seed.model { modelText = m }
            }
        }
    }

    /// EXTRACTED BECAUSE THE VIEW BODY IS NOT OBSERVABLE IN THIS TARGET.
    ///
    /// Measured: replacing the CTA's `.disabled(...)` with `.disabled(false)`
    /// left all 424 tests green — a SwiftUI modifier inside a `body` has no
    /// importable surface, so the gate had no guard at all. As a static
    /// function over its two inputs it does.
    ///
    /// BOTH halves are required because the record has no representable
    /// "partly chosen" state: `recordRoutesChoice` writes provider AND model
    /// together, and a CTA that fired on one of them would write a commission
    /// whose other half the operator never gave.
    static func routesCTAEnabled(providerPick: String?,
                                 modelText: String,
                                 shape: CredentialKind?,
                                 baseURLText: String) -> Bool {
        guard providerPick != nil else { return false }
        guard !modelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // A `.url` provider with no URL is the one shape that can pass every
        // other gate and still be unarmable: the id is chosen, a model may be
        // typed by hand, and only the endpoint is missing. Refusing here is
        // what makes `CoreArming.arm`'s NO URL arm unreachable in practice
        // rather than a screen the operator meets after commissioning.
        if case .url = shape {
            return !baseURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    /// The endpoint field for a `.url`-shape provider.
    ///
    /// `TextField`, not `SecureField`: this is an address, not a credential,
    /// and masking it would hide a typo in the one value the operator has to
    /// get exactly right.
    ///
    /// `http://localhost:11434` is the PROMPT and never the VALUE. A prefilled
    /// value is the bridge's hardcoded default moved up one layer wearing the
    /// operator's name — it would be written to the record as though he had
    /// chosen it, and on a phone it points at the phone. As a prompt it is
    /// discoverable and still has to be owned.
    private func baseURLField(for row: ProviderRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ENDPOINT")
                .font(Theme.mono(9))
                .tracking(1.4)
                .foregroundStyle(Theme.w(0.35))
            TextField("", text: $baseURLText, prompt:
                Text("http://localhost:11434").font(Theme.mono(12)).foregroundStyle(Theme.w(0.2))
            )
            .font(Theme.mono(13))
            .foregroundStyle(Theme.w(0.92))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(.URL)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(Theme.w(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .stroke(Theme.w(0.10), lineWidth: 1)
                    )
            )
            .accessibilityLabel("Endpoint for \(row.label)")
        }
    }

    /// The key field. Collectable now; it was inert until the provider-scoped
    /// Keychain landed, and the copy said so.
    ///
    /// `SecureField` rather than `TextField`: the value is a secret, and the
    /// difference is not cosmetic — an unmasked field is readable over a
    /// shoulder and is offered to the keyboard's learning cache.
    private func keyField(for row: ProviderRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API KEY")
                .font(Theme.mono(9))
                .tracking(1.4)
                .foregroundStyle(Theme.w(0.35))
            SecureField("", text: $keyText, prompt:
                Text("PASTE KEY").font(Theme.mono(12)).foregroundStyle(Theme.w(0.2))
            )
            .font(Theme.mono(13))
            .foregroundStyle(Theme.text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner)
                .fill(Theme.w(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .stroke(Theme.w(0.10), lineWidth: 1)
                )
        )
        .accessibilityLabel("API key for \(row.label)")
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
                    Image(systemName: glyph).font(Theme.display(14, .bold))
                }
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            // A floor, not a height. The sibling Text above is Theme.display(11, .bold),
            // which has scaled with Dynamic Type since the Theme routing landed, inside
            // a frame that could not grow. PRE-EXISTING, reached through Theme routing,
            // and found during the glyph walk — not caused by the glyph work.
            //
            // CLIP PREDICTED, NOT OBSERVED. display(11) at AX5 is roughly 3x — about
            // 31pt of glyph, 37pt of line — which fits 52 on ONE line. It overflows when
            // the title wraps, and Text(title) here has no lineLimit, so wrapping at AX5
            // is likely for any title longer than a word at this tracking. Likely is not
            // measured, and nothing on this branch can observe a rendered clip.
            // The fix rests on floor-not-ceiling alone, which holds either way.
            .frame(minHeight: 52)
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
