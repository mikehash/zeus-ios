import Foundation
import SwiftUI
import Speech
import AVFoundation

// MARK: - the producer question, answered before the cut
//
// B9 is "home mic → voice query". The census row said it reused "the SESSION
// mic path". THERE IS NO SUCH PATH. Measured at `cb66035` across `Sources/`:
//
//     AVAudioEngine 0 · AVAudioRecorder 0 · AVAudioSession 0
//     SFSpeechRecognizer 0 · installTap 0 · requestRecordPermission 0
//     POS ctl: the synthesiser in `Narrator.swift`, 2   NEG ctl qqzz4417 0
//
// The app could SPEAK and could not HEAR. `SessionView:251`'s mic button ran
// `{ tab = .zeus }` — a tab switch, and the comment beside it already admitted
// "the tab switch is the part that is real here". It did not say so to the
// OPERATOR, which made it a SILENT non-action: the shape retired at
// `NodesView:105` and `:191`, still live here.
//
// # The deferred arm, and why it is deferred rather than absent
//
// A producer DOES exist on the gateway: `POST /v1/stt` and its alias, both at
// `crates/zeus-api/src/routes.rs:296/298` → `voice_handlers.rs:48`. It takes a
// form upload with the field `file` and returns `{"text": …}`. It is mounted,
// and it was probed live from this box:
//
//     empty body   both routes 400 · /v1/qqzz4417 404   (mounted, discriminated)
//     real 1s 16kHz WAV:
//       http 500  "Transcription failed: No Whisper API key found.
//                  Set GROQ_API_KEY or OPENAI_API_KEY."
//
// So the endpoint does no local inference — `select_whisper_provider`
// (`zeus-voice/src/inbound.rs:487`) chooses Groq `whisper-large-v3` or OpenAI
// `whisper-1`. It EGRESSES BY CONSTRUCTION, which collides head-on with the
// `LAN BY DEFAULT · NO EGRESS` sentence in `Route.swift`. Worse, the fleet
// already HAS a no-egress transcriber — `zeus-core`'s `whisper_stt_url` /
// `ZEUS_WHISPER_URL` (whisper.cpp, canonical `http://192.168.1.5:8090`), which
// `select_whisper_provider` never reads. That is a GATEWAY defect, routed to a
// backend seat. When it lands, `/v1/stt` becomes a no-egress producer and this
// arm is buildable in an afternoon.
//
// It is NOT built here. An upload arm gated on a key nobody on this box holds
// is the fabricated-`meta`-latency defect in a different hat: plumbing that
// reads to the next maintainer as "exists, just quiet today" when it has never
// once completed.
//
// # What IS built
//
// On-device `SFSpeechRecognizer` → transcript → composer → the existing
// `/v1/chat`. No audio leaves the device, no key is needed, the no-egress
// sentence stays true, and it rides the one transport already proven.

// MARK: - the on-device guarantee, which is not a guarantee

/// The four inputs that decide whether this device can transcribe locally.
///
/// Split out as a plain value so the decision is a PURE FUNCTION of four
/// booleans. `SFSpeechRecognizer` cannot be constructed in a test process
/// without tripping authorization, so if the resolution lived inside the
/// recognizer wrapper it would be unreachable from every leg in this suite —
/// the `main.rs` shape, where logic has no importable surface.
struct VoiceCapability: Equatable {

    /// `SFSpeechRecognizer.authorizationStatus() == .authorized`.
    var speechAuthorized: Bool

    /// `AVAudioApplication.recordPermission == .granted` (iOS 17+).
    ///
    /// SEPARATE from `speechAuthorized` and not derivable from it: they are two
    /// independent OS grants behind two different plist keys, and the operator
    /// can hold one without the other.
    var micAuthorized: Bool

    /// The recognizer exists for the device's locale at all.
    var recognizerAvailable: Bool

    /// `SFSpeechRecognizer.supportsOnDeviceRecognition`.
    ///
    /// ⚠️ THE LOAD-BEARING FLAG. `requiresOnDeviceRecognition = true` is a
    /// REQUEST, not a guarantee — it is honoured only where the on-device model
    /// is actually installed for the locale. Setting the flag and shipping
    /// would make the no-egress claim depend on Apple honouring a preference
    /// the app cannot verify, which is the same class as every fabricated
    /// number deleted from this app: a promise rendered as a fact.
    ///
    /// So support is GATED, not requested. False → the operator is told the
    /// device cannot do it, and nothing is recorded.
    var supportsOnDevice: Bool

    /// Either grant missing is a DENIED, not an unavailable: the distinction is
    /// whether the operator can fix it in Settings.
    var authorizationComplete: Bool { speechAuthorized && micAuthorized }
}

/// What the composer's voice affordance is doing, and what it says.
///
/// FOUR cases, and the fifth is deliberately absent. An earlier draft of this
/// cut carried `failed(String)` to hold a non-200 body verbatim from the
/// `/v1/stt` upload. That producer is not built, so the case would be a slot
/// whose only content came from a deleted wire — i.e. a slot the next
/// maintainer fills with something invented. Deleted with its arm.
enum VoiceState: Equatable {

    /// Nothing running. The mic button is armed.
    case idle

    /// The tap is installed and the recognizer is receiving buffers.
    case listening

    /// One or both OS grants refused. FIXABLE BY THE OPERATOR, which is the
    /// whole reason it is not folded into `.unavailable`.
    case denied

    /// No recognizer for the locale, or no on-device model. NOT fixable in
    /// Settings, and not a failure the operator caused.
    case unavailable

    /// The one string each state shows, or `nil` where the button speaks for
    /// itself. Uppercase to match every other status string in this app.
    var line: String? {
        switch self {
        case .idle:        return nil
        case .listening:   return "LISTENING — TAP TO STOP"
        case .denied:      return "MIC DENIED — ENABLE IN SETTINGS"
        case .unavailable: return "VOICE UNAVAILABLE ON THIS DEVICE"
        }
    }

    /// Whether the state invites another tap on the mic.
    ///
    /// `.unavailable` is terminal for the session: re-tapping cannot change a
    /// locale or install a model, so an armed-looking button would be a lie
    /// about what a tap does.
    var isActionable: Bool {
        switch self {
        case .idle, .listening: return true
        case .denied:           return true   // Settings can fix it; the tap re-checks.
        case .unavailable:      return false
        }
    }

    /// Resolve the pre-flight state from capability alone.
    ///
    /// ORDER MATTERS and it is not arbitrary: capability is checked BEFORE
    /// authorization, because asking an operator to grant a microphone on a
    /// device that could never transcribe locally is a request with no
    /// possible payoff.
    static func preflight(_ c: VoiceCapability) -> VoiceState {
        guard c.recognizerAvailable, c.supportsOnDevice else { return .unavailable }
        guard c.authorizationComplete else { return .denied }
        return .idle
    }
}

// MARK: - the empty-transcript guard

/// What a finished recognition is allowed to do.
///
/// `SFSpeechRecognizer` returns `""` for silence, for a cough, and for a tap
/// that ended before anything was said. Dispatching that to `/v1/chat` would
/// INVENT AN UTTERANCE: the operator said nothing and the transcript claims
/// they did. It is the same defect as a fabricated latency, one layer up.
enum VoiceTranscript {

    /// The text to place in the composer, or `nil` to place nothing.
    ///
    /// Trims first, so a transcript of pure whitespace is the same as silence.
    /// Never auto-sends: the operator sees the words the device heard, and the
    /// send is still their tap. A misheard prompt dispatched without review is
    /// unrecoverable in a session that mutates a node.
    static func accepted(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - the recognizer

/// Owns the audio tap and the on-device recognition request.
///
/// ⚠️ APERTURE. Nothing in the test suite drives this class: constructing an
/// `SFSpeechRecognizer` or starting an `AVAudioEngine` in a unit-test process
/// touches the real OS grant machinery. What IS guarded is every decision it
/// makes — `VoiceState.preflight`, `VoiceTranscript.accepted` — which live
/// outside it as pure functions precisely so the untestable shell holds no
/// logic of its own. The shell is wiring; the wiring is what a device test
/// covers, and it has not been run on a device.
@MainActor
final class VoiceInput: ObservableObject {

    @Published private(set) var state: VoiceState = .idle

    /// The last accepted transcript, cleared as the composer consumes it.
    @Published var transcript: String?

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Read the four capability inputs from the OS, right now.
    ///
    /// Read fresh on every tap rather than cached at init: an operator who
    /// leaves for Settings and comes back has changed two of these four, and a
    /// cached `denied` would survive the fix.
    private func capability() -> VoiceCapability {
        VoiceCapability(
            speechAuthorized: SFSpeechRecognizer.authorizationStatus() == .authorized,
            micAuthorized: AVAudioApplication.shared.recordPermission == .granted,
            recognizerAvailable: recognizer?.isAvailable == true,
            supportsOnDevice: recognizer?.supportsOnDeviceRecognition == true
        )
    }

    /// The mic button's action. Toggles, because the button IS the stop.
    func toggle() {
        if state == .listening { stop(); return }
        Task { await start() }
    }

    private func start() async {
        // Capability BEFORE authorization — see `VoiceState.preflight`.
        let pre = capability()
        guard pre.recognizerAvailable, pre.supportsOnDevice else {
            state = .unavailable
            return
        }

        if !pre.authorizationComplete {
            await requestGrants()
        }

        let now = capability()
        state = VoiceState.preflight(now)
        guard state == .idle else { return }

        do {
            try beginTap()
            state = .listening
        } catch {
            // A tap that will not install is not a denial and not a locale
            // problem — but the operator's only lever is the same one, so it
            // reports as `.unavailable` rather than inventing a fifth state
            // with a message nobody can act on.
            state = .unavailable
        }
    }

    private func requestGrants() async {
        _ = await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { k.resume(returning: $0 == .authorized) }
        }
        _ = await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { k.resume(returning: $0) }
        }
    }

    private func beginTap() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        // THE FLAG, set in addition to the gate above — belt and braces. The
        // gate is what makes the no-egress claim true; this makes the intent
        // legible at the request itself.
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }
        engine.prepare()
        try engine.start()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result, result.isFinal {
                    // The guard: silence yields nothing, not an empty prompt.
                    self.transcript = VoiceTranscript.accepted(
                        result.bestTranscription.formattedString
                    )
                    self.stop()
                } else if error != nil {
                    self.stop()
                }
            }
        }
    }

    /// Tear down every piece, in the order that does not deadlock.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if state == .listening { state = .idle }
    }
}
