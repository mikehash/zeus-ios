import Foundation
import AVFoundation
import AudioToolbox

/// The narration engine for commissioning.
///
/// Transcribed from `817b19d3d:docs/prototypes/mobile/zeus/ZeusCommissioning.jsx`
/// (658 lines) — the `narrate()` closure at :340-366 and the `NARRATION` deck
/// at :305-312.
///
/// **The load-bearing property, from BUILD-PLAN.md § M3:** captions run on
/// their own timer and TTS is an *enhancement*. Captions must render with
/// voice off, with the synthesizer unavailable, and with the synthesizer
/// silently failing. That is an accessibility requirement, not a preference,
/// so the two paths are separated structurally here rather than by discipline:
/// `speak()` is the only function that touches `AVSpeechSynthesizer`, and
/// `caption` is advanced by a `Task` that never awaits it. There is no code
/// path in which the caption depends on the synthesizer's state.
// MARK: - the narration preference, shared across both owners

/// Where the mute toggle lives between launches.
///
/// 🔴 WHY PERSISTED AT ALL. Before this, `voiceOn` was per-instance state on a
/// narrator owned by a screen that is destroyed after onboarding — so muting
/// during commissioning was forgotten the moment the screen went away, and
/// there was no surface to mute anywhere else. An operator who turns the voice
/// off has expressed a preference about the DEVICE, not about one screen, and
/// a preference that does not survive the screen it was set on is a control
/// that narrates a choice it does not keep.
///
/// A free enum over `UserDefaults` rather than `@AppStorage` on the view: the
/// default and the key are then readable by a leg, and both owners resolve the
/// same value through one function instead of two property wrappers that could
/// drift apart on the key string.
enum NarrationPreference {

    static let key = "zeus.narration.voiceOn"

    /// Voice ON unless the operator has said otherwise. A narrator that
    /// defaults silent would make the speaking orb — the product's whole
    /// first impression — look broken on a fresh install.
    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func set(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key)
    }
}

// MARK: - speech rate, the second VOICE preference

/// How fast the orb speaks, persisted beside the mute toggle.
///
/// Three named steps rather than a slider: each step is a value a leg can
/// pin, and the Settings row cycles them with one tap. `normal` is
/// `AVSpeechUtteranceDefaultSpeechRate` — the value every utterance used
/// before this preference existed, so a fresh install sounds unchanged.
enum SpeechRatePreference: String, CaseIterable {
    case slow, normal, fast

    static let key = "zeus.narration.rate"

    var rate: Float {
        switch self {
        case .slow:   return AVSpeechUtteranceDefaultSpeechRate * 0.8
        case .normal: return AVSpeechUtteranceDefaultSpeechRate
        case .fast:   return AVSpeechUtteranceDefaultSpeechRate * 1.2
        }
    }

    var label: String { rawValue.uppercased() }

    /// The step after this one, wrapping — the Settings row's tap.
    var next: SpeechRatePreference {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    static func current(_ defaults: UserDefaults = .standard) -> SpeechRatePreference {
        defaults.string(forKey: key).flatMap(SpeechRatePreference.init(rawValue:)) ?? .normal
    }

    static func set(_ r: SpeechRatePreference, _ defaults: UserDefaults = .standard) {
        defaults.set(r.rawValue, forKey: key)
    }
}

// MARK: - which voice, the third VOICE preference

/// The orb's voice, persisted as an `AVSpeechSynthesisVoice.identifier`.
///
/// Absent key = AUTO = the pre-existing pick (named preference → en-GB → en →
/// system default), so a fresh install sounds unchanged. A stored identifier
/// that is no longer installed (voice deleted, device restored) falls back to
/// AUTO rather than to `nil`, so a stale choice can never silence or reshape
/// the orb into something the user did not pick.
enum VoicePreference {
    static let key = "zeus.narration.voice"
    static let preferredNames = ["Daniel", "Alex", "Aaron"]

    /// The English voices the Settings row cycles through, stable-ordered.
    static func choices(_ voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        voices.filter { $0.language.hasPrefix("en") }
              .sorted { ($0.name, $0.identifier) < ($1.name, $1.identifier) }
    }

    static func storedID(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    /// `nil` clears the key — AUTO.
    static func set(_ id: String?, _ defaults: UserDefaults = .standard) {
        if let id { defaults.set(id, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    static func auto(_ voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        for name in preferredNames {
            if let hit = voices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return hit
            }
        }
        return voices.first { $0.language == "en-GB" }
            ?? voices.first { $0.language.hasPrefix("en") }
    }

    static func resolve(defaults: UserDefaults = .standard,
                        voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        if let id = storedID(defaults), let hit = voices.first(where: { $0.identifier == id }) {
            return hit
        }
        return auto(voices)
    }

    /// AUTO → each choice in order → AUTO. An unknown stored id restarts at the first choice.
    static func next(after id: String?, in voices: [AVSpeechSynthesisVoice]) -> String? {
        let list = choices(voices)
        guard !list.isEmpty else { return nil }
        guard let id, let i = list.firstIndex(where: { $0.identifier == id }) else {
            return list[0].identifier
        }
        return i + 1 < list.count ? list[i + 1].identifier : nil
    }

    static func label(_ id: String?, in voices: [AVSpeechSynthesisVoice]) -> String {
        guard let id, let v = voices.first(where: { $0.identifier == id }) else { return "AUTO" }
        return v.name.uppercased()
    }
}

/// The one place an utterance is shaped. `Narrator.speak()` calls this, so a
/// leg that reads the returned utterance reads what the synthesizer is given.
enum UtteranceShape {
    static func make(_ line: String, pitch: Float,
                     defaults: UserDefaults = .standard,
                     voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: line)
        u.pitchMultiplier = pitch
        u.rate = SpeechRatePreference.current(defaults).rate
        u.voice = VoicePreference.resolve(defaults: defaults, voices: voices)
        return u
    }
}

// MARK: - which reply the orb speaks, decided out here

/// The pure half of reply narration.
///
/// WHY THIS EXISTS AS A FREE ENUM. `Narrator` is a `@MainActor` class wrapping
/// `AVSpeechSynthesizer`; a view is not observable in-process. Both are
/// unguardable, so the DECISION — which message, and whether it has already
/// been spoken — lives out here where a leg can reach it, exactly as
/// `VoiceState.preflight` and `VoiceTranscript.accepted` do in `Voice.swift`.
///
/// 🔴 THE THREE REFUSALS, each for a defect it prevents:
///
///   * a `.user` message is never spoken — the operator does not need their
///     own words read back, and speaking them would make a send sound like
///     a reply;
///   * a `streaming` message is never spoken — the text is still arriving, so
///     narrating it would speak a PREFIX of an answer and then fall silent
///     mid-sentence, which is the same class as the REMEMBER suppression on a
///     streaming bubble (`SessionView:698`);
///   * an already-spoken `id` is never spoken twice — `messages` republishes
///     on every token, so an un-deduplicated wire would restart the utterance
///     dozens of times per reply.
enum ReplyNarration {

    /// The one message the orb should speak now, or `nil` for none.
    ///
    /// Returns the LAST eligible message rather than the first: an operator
    /// who sent two prompts quickly wants the answer to the latest one, and
    /// a queue of stale replies read in order would talk over the session.
    static func nextToSpeak(messages: [Message], spoken: Set<UUID>) -> Message? {
        messages.last { candidate in
            candidate.role == .agent
                && !candidate.streaming
                && !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !spoken.contains(candidate.id)
        }
    }
}

@MainActor
final class Narrator: ObservableObject {

    /// The line currently being typed out, character-prefix of `full`.
    @Published private(set) var caption: String = ""
    /// True while the caption is still being revealed — drives the blinking
    /// caret at :492-498 and the orb's `speaking` mode.
    @Published private(set) var isNarrating: Bool = false
    /// Voice toggle. `voiceOn` at :328. Off suppresses TTS only.
    /// Seeded from the persisted preference and written back on every change,
    /// so the two owners (commissioning, reply narration) agree and the
    /// choice survives the screen it was made on.
    @Published var voiceOn: Bool = NarrationPreference.isOn() {
        didSet {
            NarrationPreference.set(voiceOn)
            if !voiceOn { synth.stopSpeaking(at: .immediate) }
        }
    }

    private let synth = AVSpeechSynthesizer()
    private var revealTask: Task<Void, Never>?

    /// Per-character reveal interval. The prototype types at ~28ms/char
    /// (:344); at 60Hz that is a hair under two frames, which is the
    /// closest a display-linked reveal can get to it.
    private static let charInterval: Duration = .milliseconds(28)

    /// Voice selection, `pitch 0.9` and the preference list at :356-361.
    /// Optimus uses a warm female voice at pitch 1.05 — the two products
    /// deliberately sound different, so this constant is product identity
    /// and not a default to be tidied away.
    private static let pitch: Float = 0.9

    func narrate(_ line: String) {
        revealTask?.cancel()
        caption = ""
        isNarrating = true

        // Caption path — independent of everything below it.
        revealTask = Task { [weak self] in
            guard let self else { return }
            for index in line.indices {
                if Task.isCancelled { return }
                self.caption = String(line[...index])
                try? await Task.sleep(for: Self.charInterval)
            }
            self.isNarrating = false
        }

        // Enhancement path. Failure here is silent and costs the user nothing.
        if voiceOn { speak(line) }
    }

    func stop() {
        revealTask?.cancel()
        revealTask = nil
        isNarrating = false
        synth.stopSpeaking(at: .immediate)
    }

    private func speak(_ line: String) {
        synth.stopSpeaking(at: .immediate)
        SpeechAudio.prepare(AVAudioSession.sharedInstance())
        let utterance = UtteranceShape.make(line, pitch: Self.pitch)
        synth.speak(utterance)
    }

}

// MARK: - wake chime, the fourth VOICE preference

/// A short system tone when the mic actually opens — the audible half of
/// "I'm listening". Default OFF: a fresh install sounds exactly as it did
/// before this row existed, and the operator opts in from Settings.
/// VOICE → REPLY LENGTH. Persisted here, enforced in the core: the bridge
/// writes the matching section into the phone's AGENTS.md, which heads the
/// prompt `get_context` assembles. `normal` writes nothing, so a fresh install's
/// prompt is unchanged. On a remote gateway the prompt is built server-side and
/// this setting cannot fire — the row says so instead of pretending.
enum ReplyLengthPreference: String, CaseIterable {
    case brief, normal, detailed

    static let key = "zeus.voice.replyLength"

    var label: String { rawValue.uppercased() }

    var next: ReplyLengthPreference {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// The bridge's value. Exhaustive, so a new case cannot compile unmapped.
    var ffi: ReplyLength {
        switch self {
        case .brief:    return .brief
        case .normal:   return .normal
        case .detailed: return .detailed
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> ReplyLengthPreference {
        defaults.string(forKey: key).flatMap(ReplyLengthPreference.init(rawValue:)) ?? .normal
    }

    static func set(_ r: ReplyLengthPreference, _ defaults: UserDefaults = .standard) {
        defaults.set(r.rawValue, forKey: key)
    }

    /// Hand the stored choice to the core. The ONE production caller is
    /// `RootView.armedResolution`, which runs on app start and on every
    /// re-arm — including the one the Settings row raises.
    static func apply(to core: SessionCapabilities?, _ defaults: UserDefaults = .standard) {
        try? core?.setReplyLength(current(defaults).ffi)
    }
}

enum WakeChimePreference {
    static let key = "zeus.voice.wakeChime"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }

    static func set(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key)
    }
}

/// The one decision the mic makes: which tone, if any. Pure, so a leg can
/// read it; `play` is the only caller of the system-sound API.
enum WakeChime {
    /// iOS `begin_record` tone.
    static let tone: UInt32 = 1113

    static func sound(_ defaults: UserDefaults = .standard) -> UInt32? {
        WakeChimePreference.isOn(defaults) ? tone : nil
    }

    static func play(_ defaults: UserDefaults = .standard) {
        guard let id = sound(defaults) else { return }
        AudioServicesPlaySystemSound(SystemSoundID(id))
    }
}
