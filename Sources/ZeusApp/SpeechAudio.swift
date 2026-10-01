import AVFoundation

/// The audio-session seam the narrator speaks through.
///
/// 🔴 WHY THIS EXISTS (merakizzz, 2026-10-01: "the orb doesn't talk to me").
/// `Voice.beginTap` sets the shared session to `.record`, and nothing ever
/// set it back — a `.record` session renders no output, so every reply after
/// the first mic use was silent until relaunch. Before any mic use the session
/// was the default `.soloAmbient`, which the ring/silent switch mutes. Speech
/// therefore re-asserts a playback category on EVERY utterance, not once.
protocol SpeechAudioSession: AnyObject {
    func setCategory(_ category: AVAudioSession.Category,
                     mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: SpeechAudioSession {}

enum SpeechAudio {
    /// `.playback` sounds through the silent switch; `.spokenAudio` lets other
    /// spoken-word apps pause rather than mix; `.duckOthers` lowers music.
    static let category: AVAudioSession.Category = .playback
    static let mode: AVAudioSession.Mode = .spokenAudio
    static let options: AVAudioSession.CategoryOptions = [.duckOthers]

    /// Returns whether the session was put into a speakable state. A failure
    /// is not fatal: the caption path never depends on speech (Narrator.swift).
    @discardableResult
    static func prepare(_ session: SpeechAudioSession) -> Bool {
        do {
            try session.setCategory(category, mode: mode, options: options)
            try session.setActive(true, options: [])
            return true
        } catch {
            return false
        }
    }
}
