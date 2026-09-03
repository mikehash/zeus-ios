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
        return Commission(route: .managed, callsign: "ATLAS", nodeEnrolled: true)
        #else
        return nil
        #endif
    }

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

    /// `-zeusStep welcome|auth|routes|nodes|callsign|done` — open the
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

    // MARK: - Primitives

    private static func has(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
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
