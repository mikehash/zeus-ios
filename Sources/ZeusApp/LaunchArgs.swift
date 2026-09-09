import Foundation

/// Launch-argument seam for deterministic screen capture.
///
/// WHY THIS EXISTS: the console is gated behind commissioning — `ZeusApp`
/// holds `Commission?` and `nil` means unreachable, deliberately. So a plain
/// `simctl launch` can only ever photograph screen one, and `simctl` has no
/// tap primitive to walk past it. Without a seam, capturing the SESSION or
/// NODES tab requires a human driving the simulator by hand, which is not a
/// thing that can run in CI or be repeated identically for App Store assets.
///
/// WHAT IT IS NOT: a way to skip commissioning in a shipped build. Every
/// member is `#if DEBUG`; in a release configuration `seededCommission`
/// returns `nil` and `initialTab` returns `.zeus` unconditionally, so the
/// gate is structurally intact where it matters. The arguments are also
/// inert unless passed — a normal debug launch behaves exactly as before.
///
/// APERTURE: this seeds *state*, it does not simulate a user. A screenshot
/// taken through `-zeusSeedCommission` proves the console renders given a
/// commission; it proves nothing about whether the commissioning flow can
/// produce one. That claim needs the flow itself, which is why screen one is
/// still captured by an unargumented launch.
enum LaunchArgs {

    /// `-zeusSeedCommission` — bypass the gate with a fixed commission.
    ///
    /// Values are literals rather than defaults so the captured frames are
    /// byte-identical across runs; a `Commission()` default that later gains
    /// a timestamp would make two captures of the same screen differ.
    static var seededCommission: Commission? {
        #if DEBUG
        guard has("-zeusSeedCommission") else { return nil }
        return captureSeed
        #else
        return nil
        #endif
    }

    /// The seeded value, EXPOSED SEPARATELY FROM THE FLAG THAT GATES IT.
    ///
    /// `seededCommission` is unreachable from a test process: it is `nil`
    /// unless `-zeusSeedCommission` is in `ProcessInfo.arguments`, and the
    /// xctest runner's argv is not ours to set. So a test that asserts on a
    /// LOCALLY RECONSTRUCTED `Commission(...)` literal is asserting on a copy
    /// — it passes with this constant mutated back to `.managed`, which is
    /// precisely the mutation the ruling's leg exists to kill. Measured: the
    /// reconstruction survived; reading this constant kills it.
    #if DEBUG
    static var captureSeed: Commission {
        // SEEDS A MODE THAT EXISTS. This was `.managed`, which meant every
        // captured frame photographed the summary line of a route mode the
        // shipping app can no longer produce. The provider id is one
        // `Provider::from_prefix` accepts (zeus-core:8922) — never a literal
        // the core would refuse, or the capture would document a state the
        // bridge rejects on the first send.
        return Commission(route: .byok,
                          provider: "anthropic",
                          callsign: "ATLAS",
                          // (f): `false`, because `true` is a state no
                          // production path can reach — seeding it made the
                          // captured frames document a fiction.
                          nodeEnrolled: false)
    }
    #endif

    /// `-zeusTab zeus|session|nodes` — which tab `RootView` opens on.
    ///
    /// Falls back to `.zeus` on an unrecognised value rather than trapping:
    /// a capture script with a typo should photograph the wrong screen
    /// loudly, not crash and leave no artefact to notice.
    static var initialTab: Tab {
        #if DEBUG
        guard let raw = value(for: "-zeusTab"), let tab = Tab(rawValue: raw) else {
            return .zeus
        }
        return tab
        #else
        return .zeus
        #endif
    }

    /// `-zeusStep welcome|fork|auth|routes|nodes|callsign|done` — open the
    /// commissioning flow at a given step. Ignored when the gate is seeded,
    /// because a seeded commission means the flow is not on screen at all.
    static var initialStep: CommissioningStep {
        #if DEBUG
        guard let raw = value(for: "-zeusStep"),
              let step = CommissioningStep(rawValue: raw) else { return .welcome }
        return step
        #else
        return .welcome
        #endif
    }

    /// `-zeusPick <id> [<model>]` — preselect a ROUTES row, and optionally
    /// type the model, so the KEYED state is photographable.
    ///
    /// WHY IT EXISTS: `-zeusStep routes` opens the step with
    /// `providerPick == nil`, which is one tap short of the only state worth
    /// photographing — the `SecureField` and the enabled model field are
    /// revealed by a row TAP, and `simctl` has no tap primitive. So the
    /// capture set could show that the picker renders from the core's
    /// catalog, and could not show what a chosen keyed provider looks like.
    /// That gap was stated on the channel rather than papered over; this
    /// closes it.
    ///
    /// ## It writes VIEW state, not the record
    ///
    /// The returned id lands in `providerPick` and the model in `modelText` —
    /// the same two `@State` fields a tap and a keystroke write. It does NOT
    /// call `recordRoutesChoice`, so "was shown a preselection" and "chose"
    /// stay distinguishable in the stored record exactly as they are for a
    /// human. A frame captured through this proves the keyed row RENDERS;
    /// it proves nothing about whether CONTINUE writes, which is
    /// `CommissionStoreTests`' subject and not a screenshot's.
    ///
    /// NO KEY OPERAND, deliberately. A flag that seeded `keyText` would put a
    /// secret-shaped literal on a command line and into shell history for the
    /// sake of photographing dots. The field renders its prompt state, which
    /// is the state that differs from the disabled one.
    ///
    /// APERTURE: `#if DEBUG`, inert in release, inert unless passed. The id
    /// is NOT validated against the catalog here — an unknown id preselects
    /// nothing, because `routesStep` matches rows by id and a miss simply
    /// leaves the picker unselected. That is the honest failure: the frame
    /// shows an unselected picker rather than a fabricated row.
    static var pickedRoute: (id: String, model: String?)? {
        #if DEBUG
        guard let id = value(for: "-zeusPick") else { return nil }
        // The model is an OPTIONAL second positional. Read via `value(for:)`
        // semantics at the offset rather than assumed present: a bare
        // `-zeusPick anthropic` is a legitimate invocation that photographs
        // the row selected with the model field empty — which is itself a
        // state the CTA gate refuses, and worth a frame.
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-zeusPick"),
              let m = args.index(i, offsetBy: 2, limitedBy: args.endIndex),
              m < args.endIndex,
              !args[m].hasPrefix("-")
        else { return (id, nil) }
        return (id, args[m])
        #else
        return nil
        #endif
    }

    /// `-zeusMuteVoice` — suppress narration during capture.
    ///
    /// Not cosmetic: `AVSpeechSynthesizer` drives the orb's `.speaking` mode,
    /// so an unmuted capture photographs a *different orb* depending on where
    /// in the utterance the shutter lands. Muting makes the frame reproducible.
    static var muteVoice: Bool {
        #if DEBUG
        return has("-zeusMuteVoice")
        #else
        return false
        #endif
    }

    /// `-zeusAutoSend` — commit the prefilled prompt once, through the
    /// composer's OWN send action.
    ///
    /// WHY IT EXISTS: `simctl` has no tap primitive and this project has no
    /// XCUITest target (`project.yml`: `bundle.ui-testing` == 0), so a
    /// capture script can seed a prompt into the composer via
    /// `zeus://session?prompt=…` and then has no way to press SEND. Without
    /// this the strongest obtainable frame photographs a composer HOLDING a
    /// prompt — which proves the deep link, and proves nothing about a reply.
    ///
    /// WHAT IT DOES NOT DO: it commits nothing of its own. It invokes
    /// `SessionView.send`, the exact function the SEND button's `action:`
    /// invokes, so the guard inside `send()` (`canSend`) refuses a disarmed
    /// composer here identically. A seam that built its own turn would be
    /// measuring itself.
    ///
    /// WHY A LAUNCH ARGUMENT AND NEVER A URL FIELD: `zeus://` is reachable by
    /// any app on the phone. An `&autosend=1` parameter would let a third
    /// party make Zeus send a prompt of their choosing. Launch arguments are
    /// settable only by whoever launches the process, which on a device is
    /// the operator with a debug build. Refused in production by construction:
    /// `#if DEBUG` like every other member, `false` in release.
    ///
    /// APERTURE: this commits a turn, it does not simulate a tap. A frame
    /// captured through it proves the send PATH — composer → `onSend` →
    /// engine → transport → transcript — and proves nothing about whether the
    /// SEND button is hittable, positioned, or enabled on screen. That claim
    /// needs the XCUITest target this seam exists because we do not have.
    static var autoSend: Bool {
        #if DEBUG
        return has("-zeusAutoSend")
        #else
        return false
        #endif
    }

    /// `-zeusPrompt <text>` — seed the composer's prefill without a URL.
    ///
    /// WHY IT EXISTS: the capture chain reached the composer through
    /// `zeus://session?prompt=…`, which requires `simctl openurl` to land
    /// AFTER the app is foreground. On a cold launch that ordering is a race
    /// the capture script loses silently — the frame photographs an empty
    /// composer and reads as "the seam did not fire" when what happened is
    /// the URL arrived before the scene existed.
    ///
    /// IT WRITES THE SAME BINDING THE DEEP LINK WRITES. `RootView`'s
    /// `pendingPrompt` is initialised from this value, so `applyPrefill` and
    /// the auto-send seam behind it are UNTOUCHED: nothing downstream can
    /// tell a seeded prompt from a deep-linked one, which is the point — a
    /// capture through here exercises the production ingestion path.
    ///
    /// WHAT IT DOES NOT PROVE: that `zeus://session?prompt=` works. That
    /// claim belongs to `DeepLinkTests`, which still holds it. A frame taken
    /// through this seed proves the COMPOSER path, not the URL path.
    ///
    /// APERTURE: `#if DEBUG`, `nil` in release, inert unless passed.
    static var seededPrompt: String? {
        #if DEBUG
        return value(for: "-zeusPrompt")
        #else
        return nil
        #endif
    }

    // MARK: - Primitives

    private static func has(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    /// `-zeusInMemoryTokens` — the token-store seam for capture and tests.
    ///
    /// The Keychain is per-device and per-credential-prompt; a capture run or
    /// a test that exercised the real `GatewayTokenStore` would be asserting
    /// on whatever the host Mac's keychain happened to hold. This flag routes
    /// `RootView` to `InMemoryTokenStore` through the same launch-argument
    /// seam the commission seed uses — one construction site, one switch.
    /// `#if DEBUG` like every other member: inert in release.
    static var useInMemoryTokens: Bool {
        #if DEBUG
        return has("-zeusInMemoryTokens")
        #else
        return false
        #endif
    }

    /// `-zeusProvider <id> <model> [<baseURL>]` — seed the commission's
    /// provider/model so THE PRODUCTION PATH arms the core.
    ///
    /// ## It seeds the COMMISSION, it does not call `setProvider`
    ///
    /// The point of the seam is that the sole production `setProvider` call
    /// (`RootView.init` → `CoreArming.arm`) is the one that runs. A DEBUG flag
    /// that armed the core itself would prove the bridge works and say nothing
    /// about the app a person launches — which is exactly the gap the live
    /// streamed-reply test had: it armed the core FROM THE TEST.
    ///
    /// APERTURE: same as every member here — `#if DEBUG`, inert in release,
    /// inert unless passed. And it seeds STATE: a frame captured through it
    /// proves the console sends given a provider, never that ROUTES can
    /// obtain one.
    static var seededProvider: (id: String, model: String, baseURL: String?)? {
        #if DEBUG
        guard let id = value(for: "-zeusProvider") else { return nil }
        // The model is the SECOND positional, read explicitly rather than via
        // `value(for:)` — a flag with one operand is a malformed invocation
        // here, and defaulting the model would put a literal model name back
        // into the app through the debug door.
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-zeusProvider"),
              args.index(i, offsetBy: 2, limitedBy: args.endIndex) != nil else { return nil }
        let model = args[args.index(i, offsetBy: 2)]
        guard !model.hasPrefix("-") else { return nil }
        let urlIndex = args.index(i, offsetBy: 3, limitedBy: args.endIndex)
        var baseURL: String? = nil
        if let u = urlIndex, u < args.endIndex, !args[u].hasPrefix("-") { baseURL = args[u] }
        return (id, model, baseURL)
        #else
        return nil
        #endif
    }

    /// Reads `-flag value`. Returns `nil` when the flag is absent OR is the
    /// final argument — a trailing flag with no operand is a malformed
    /// invocation, and answering it with the *next* flag's name would be a
    /// silent misread.
    private static func value(for flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), args.index(after: i) < args.endIndex else {
            return nil
        }
        let candidate = args[args.index(after: i)]
        return candidate.hasPrefix("-") ? nil : candidate
    }
}
