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
@MainActor
final class Narrator: ObservableObject {

    /// The line currently being typed out, character-prefix of `full`.
    @Published private(set) var caption: String = ""
    /// True while the caption is still being revealed — drives the blinking
    /// caret at :492-498 and the orb's `speaking` mode.
    @Published private(set) var isNarrating: Bool = false
    /// Voice toggle. `voiceOn` at :328. Off suppresses TTS only.
    @Published var voiceOn: Bool = true {
        didSet { if !voiceOn { synth.stopSpeaking(at: .immediate) } }
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
