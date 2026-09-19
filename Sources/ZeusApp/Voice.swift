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

// MARK: - the meter

/// Turns one captured audio buffer into the orb's `level`.
///
/// WHY THIS EXISTS. `DeviceOrb.level` is documented as "audio level 0...1"
/// (`DeviceOrb.swift:69`) and every production site passes it a LITERAL:
/// `Commissioning:534` passes `narrator.isNarrating ? 0.7 : 0.2`, and
/// `HomeView.orbLevel` says so in its own words — "THIS IS NOT AN AUDIO
/// AMPLITUDE AND MUST NOT BE READ AS ONE". Those two are honest, because
/// neither screen meters anything. A voice surface that pulsed the orb on a
/// literal would NOT be honest: the picture would claim to be listening while
/// reading a constant, which is the costume defect at the most visible surface
/// in the app. `VoiceInput` already holds the real PCM frames — `beginTap`
/// receives them and appends them to the recognizer — so the amplitude is not
/// new capture, it is a read of data already in hand and already discarded.
///
/// PURE BY CONSTRUCTION, for the reason this file states above `VoiceInput`:
/// the shell is untestable, so it must hold no decisions. The mapping from
/// samples to energy is a decision, so it lives out here where legs reach it.
enum VoiceMeter {

    /// Root-mean-square energy of `samples`, mapped to `0...1`.
    ///
    /// RMS rather than peak: a single clipped sample would pin a peak meter to
    /// 1 for the whole buffer, so the orb would read one click as sustained
    /// speech. RMS is the energy the ear reports.
    ///
    /// An EMPTY buffer yields 0 and not a carried-forward value. "No frames
    /// arrived" is not "silence was heard", but both are legitimately drawn as
    /// a still orb; what would be a lie is inventing motion for a buffer that
    /// never came.
    static func level(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for s in samples {
            let v = Double(s)
            sum += v * v
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        return normalize(rms)
    }

    /// The quietest RMS drawn as motion.
    ///
    /// Room tone on a phone mic sits around -60 dBFS. Mapping linearly from 0
    /// would render an empty room as a live orb, so the floor is subtracted
    /// rather than the range stretched.
    static let floor = 0.0025

    /// RMS at which the orb is fully energetic. Conversational speech at arm's
    /// length lands well under 1.0 RMS, so a full-scale ceiling would leave the
    /// orb nearly dormant through an entire sentence.
    static let ceiling = 0.25

    /// Map an RMS reading onto the orb's `0...1`, clamped at both ends.
    ///
    /// Clamped rather than trusted: `level` is read straight into the
    /// renderer's displacement term (`DeviceOrb:511`), and a value above 1
    /// would put geometry outside the shape the tuning describes.
    static func normalize(_ rms: Double) -> Double {
        guard rms > floor else { return 0 }
        let span = ceiling - floor
        return min(1, (rms - floor) / span)
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

    /// Live microphone energy, `0...1`, for `DeviceOrb.level`.
    ///
    /// Zero whenever the tap is not installed — see `stop()`. A meter that
    /// held its last reading after teardown would draw a listening orb over a
    /// dead microphone, which is the same class as a stale badge surviving the
    /// state it described.
    @Published private(set) var level: Double = 0

    /// The most recent reading the recognizer produced, final or partial.
    ///
    /// NOT `@Published` and not the composer's channel: `transcript` is what
    /// the composer consumes, and it is written exactly once per capture by
    /// `finish()`. This is the working value the finalize reads FROM, so a
    /// half-heard sentence never reaches a surface that could send it.
    private var latest: String = ""

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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req, weak self] buffer, _ in
            req?.append(buffer)
            // The meter reads the SAME buffer the recognizer receives — one
            // capture, two readers. A second tap would be a second aperture,
            // and two meters of one microphone can disagree.
            let energy = VoiceMeter.level(Self.samples(of: buffer))
            Task { @MainActor in self?.level = energy }
        }
        engine.prepare()
        try engine.start()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    // EVERY result is retained, not only the final one.
                    //
                    // 🔴 WHY. `shouldReportPartialResults` is true above and
                    // nothing used to read a partial: only `isFinal` wrote
                    // `transcript`. With `requiresOnDeviceRecognition`, the
                    // final arrives ASYNCHRONOUSLY after `endAudio()` — and
                    // `stop()` cancelled the task on the next line, so on the
                    // stop path the final never arrived and the whole
                    // utterance was discarded in silence. Retaining each
                    // partial means the last reading the recognizer produced
                    // is in hand BEFORE any teardown, so a stop can finalize
                    // from it. The final still wins when it arrives: it
                    // overwrites the partial with the recognizer's own best
                    // transcription, which is why this is a fallback and not
                    // a replacement.
                    self.latest = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finish()
                    }
                } else if error != nil {
                    // An ERROR is an abort, and an abort must not publish.
                    // A recognizer that failed mid-utterance holds a prefix
                    // of what was said, and dispatching that would invent a
                    // shorter sentence the operator never finished — the
                    // same class as the empty-transcript bug one step up.
                    self.abort()
                }
            }
        }
    }

    /// Copy the first channel of `buffer` out as plain samples.
    ///
    /// Returns empty for a buffer carrying no float data rather than
    /// substituting silence-shaped zeros: `VoiceMeter.level` already maps
    /// empty to 0, so the absence is expressed once, in the pure function that
    /// the legs can reach.
    nonisolated static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel,
                                         count: Int(buffer.frameLength)))
    }

    /// The operator's stop. Ends the audio and PUBLISHES what was heard.
    ///
    /// 🔴 THE DEFECT THIS REPLACES. The old `stop()` called `endAudio()` and
    /// `task?.cancel()` on consecutive lines. `endAudio()` ASKS for the final
    /// result; `cancel()` discards the task before it can arrive. Since only
    /// `isFinal` wrote `transcript`, every utterance ended by the stop button
    /// was thrown away — the mic recorded, the orb returned to idle, and
    /// nothing was ever sent. It failed silently, which is why it read as
    /// "voice doesn't work" rather than as an error.
    ///
    /// The teardown order is unchanged and still load-bearing; what changed
    /// is that `finish()` runs on this path, publishing the retained reading
    /// rather than dropping it.
    func stop() {
        request?.endAudio()
        finish()
    }

    /// Publish the retained transcript and tear down.
    ///
    /// Called from BOTH ends of a successful capture — the operator's stop
    /// and the recognizer's own final — so there is exactly one site that
    /// writes `transcript`, and it cannot disagree with itself.
    private func finish() {
        // The guard: silence yields nothing, not an empty prompt. Applied to
        // the retained reading, so the property that made a blank utterance
        // unsendable holds on the stop path too.
        transcript = VoiceTranscript.accepted(latest)
        teardown()
    }

    /// Tear down WITHOUT publishing. The abort path.
    private func abort() {
        teardown()
    }

    /// Tear down every piece, in the order that does not deadlock.
    private func teardown() {
        // Zeroed FIRST: the tap is removed on the next line, so any later
        // reset would race a renderer already drawing the last live value.
        level = 0
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        latest = ""
        if state == .listening { state = .idle }
    }
}
