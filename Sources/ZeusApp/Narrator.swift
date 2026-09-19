import Foundation
import AVFoundation

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
    private static let preferredVoices = ["Daniel", "Alex", "Aaron"]

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
        let utterance = AVSpeechUtterance(string: line)
        utterance.pitchMultiplier = Self.pitch
        utterance.voice = Self.pickVoice()
        synth.speak(utterance)
    }

    /// Falls back through: named preference → any en-GB → any en → nil.
    /// `nil` is legal and means "system default voice", so this cannot
    /// throw and cannot leave the utterance unspeakable.
    private static func pickVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        for name in preferredVoices {
            if let hit = voices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return hit
            }
        }
        return voices.first { $0.language == "en-GB" }
            ?? voices.first { $0.language.hasPrefix("en") }
    }
}
