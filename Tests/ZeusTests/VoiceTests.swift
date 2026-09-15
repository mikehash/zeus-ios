import XCTest
@testable import Zeus

/// Legs for B9 — on-device voice input.
///
/// ⚠️ APERTURE, first, because it decides what these legs are worth.
///
/// Nothing here constructs an `SFSpeechRecognizer` or starts an
/// `AVAudioEngine`. Both touch the real OS authorization machinery, and a unit
/// test process that trips them either hangs on a permission sheet nobody can
/// tap or dies for want of a usage string. So `VoiceInput` — the class that
/// owns the tap — is NOT exercised by this file.
///
/// That is exactly why it holds no decisions. Every judgment the feature makes
/// lives outside it as a pure function of plain values — `VoiceState.preflight`
/// over a `VoiceCapability`, and `VoiceTranscript.accepted` over a `String` —
/// and those are what is guarded below. `VoiceInput` is wiring: it reads four
/// OS booleans, hands them to `preflight`, and installs or removes a tap. What
/// it cannot be caught doing here is deciding something on its own.
///
/// What is therefore UNPROVEN by any leg in this suite: that the tap installs,
/// that a real utterance transcribes, that the recogniser honours
/// `requiresOnDeviceRecognition`, and that the two plist keys are read at the
/// moment the OS asks for them. The first three need a device. The fourth is
/// covered structurally by `BundleResourceTests`.
final class VoiceTests: XCTestCase {

    // MARK: - fixtures

    /// Every input true — the device that can do it and has been allowed to.
    private func capable(
        speech: Bool = true,
        mic: Bool = true,
        available: Bool = true,
        onDevice: Bool = true
    ) -> VoiceCapability {
        VoiceCapability(
            speechAuthorized: speech,
            micAuthorized: mic,
            recognizerAvailable: available,
            supportsOnDevice: onDevice
        )
    }

    // MARK: - the on-device gate

    /// THE LOAD-BEARING LEG OF THIS FEATURE.
    ///
    /// `requiresOnDeviceRecognition = true` is a REQUEST. Where the on-device
    /// model is not installed for the locale, the flag does not hold the audio
    /// back — and an implementation that merely set it would make the app's
    /// no-egress claim depend on a promise it cannot verify. That is the same
    /// class as every fabricated number deleted from this app.
    ///
    /// So support is GATED. This leg is the difference between the two.
    func testAnUnsupportedDeviceIsRefusedRatherThanDowngraded() {
        let noModel = capable(onDevice: false)
        XCTAssertEqual(
            VoiceState.preflight(noModel), .unavailable,
            "a device without an on-device model resolved to something other "
                + "than .unavailable — the flag alone would let audio egress"
        )

        // The discriminator: it is NOT the same answer as a fully-capable
        // device. Without this arm, an implementation that returned
        // `.unavailable` for EVERYTHING would pass the assertion above.
        XCTAssertNotEqual(
            VoiceState.preflight(noModel),
            VoiceState.preflight(capable()),
            "preflight collapsed — an unsupported device and a capable one "
                + "must not resolve to the same state"
        )
    }

    /// Capability is read BEFORE authorization, and the order is a decision.
    ///
    /// A device with no on-device model reports `.unavailable` even when both
    /// grants are missing — because asking an operator for a microphone on a
    /// device that could never transcribe locally is a prompt with no possible
    /// payoff, and `MIC DENIED — ENABLE IN SETTINGS` would send them to
    /// Settings to fix something Settings does not contain.
    func testCapabilityOutranksAuthorization() {
        let hopeless = capable(speech: false, mic: false, onDevice: false)
        XCTAssertEqual(
            VoiceState.preflight(hopeless), .unavailable,
            "an unsupported device with missing grants reported .denied — "
                + "that sends the operator to Settings for a missing model"
        )
    }

    // MARK: - denied is its own state

    /// `MIC DENIED` is separate from `VOICE UNAVAILABLE` because exactly one
    /// of them is fixable by the person reading it.
    ///
    /// Both grants are checked, and EITHER missing is a denial — they are two
    /// independent OS permissions behind two different plist keys, and an
    /// operator can hold one without the other.
    func testEitherMissingGrantIsADenialAndTheTwoAreIndependent() {
        XCTAssertEqual(VoiceState.preflight(capable(speech: false)), .denied)
        XCTAssertEqual(VoiceState.preflight(capable(mic: false)), .denied)

        // Vacuity guard: `.denied` must not be what a capable device returns.
        XCTAssertNotEqual(
            VoiceState.preflight(capable()), .denied,
            "a fully-authorized capable device reported .denied"
        )
        XCTAssertEqual(VoiceState.preflight(capable()), .idle)
    }

    /// The four states are FOUR — no two share a string, a glyph decision, or
    /// an actionability.
    ///
    /// Written as an exhaustive walk over `line` so that a fifth case added
    /// later without a string is caught here rather than shipping as a blank
    /// row above the composer.
    func testEveryNonIdleStateSaysSomethingAndNoTwoSayTheSame() {
        let speaking: [VoiceState] = [.listening, .denied, .unavailable]
        let lines = speaking.map { state -> String in
            guard let l = state.line else {
                XCTFail("\(state) renders no line — a silent non-action")
                return ""
            }
            return l
        }
        XCTAssertEqual(
            Set(lines).count, speaking.count,
            "two voice states render the same string — the operator cannot "
                + "tell them apart, which is the collapse this cut retires"
        )

        // `.idle` is the one state that says NOTHING, deliberately: a
        // persistent "ready" line is status chrome for the absence of status.
        XCTAssertNil(VoiceState.idle.line)
    }

    /// `.unavailable` does not arm the button.
    ///
    /// A normal-looking mic whose tap cannot work is precisely the silent
    /// non-action retired with the kitchen block's revoke sheet at (d)
    /// (`NodesView`, `60d2f06b^`; the coordinates :105/:191 are gone with it). `.denied` DOES stay
    /// actionable, because a trip to Settings and back can change the answer
    /// and the re-tap is what re-reads it.
    func testOnlyTheUnfixableStateDisarmsTheButton() {
        XCTAssertFalse(VoiceState.unavailable.isActionable)
        XCTAssertTrue(VoiceState.denied.isActionable,
                      "denied disarmed the button — Settings can fix it, and "
                        + "the re-tap is the only thing that re-reads the grant")
        XCTAssertTrue(VoiceState.idle.isActionable)
        XCTAssertTrue(VoiceState.listening.isActionable)
    }

    // MARK: - the empty-transcript guard

    /// SILENCE IS NOT AN UTTERANCE.
    ///
    /// `SFSpeechRecognizer` returns `""` for silence, for a cough, and for a
    /// tap that ended before anything was said. Placing that in the composer
    /// and dispatching it would claim the operator said something they did
    /// not — a fabricated input, one layer up from a fabricated latency.
    func testSilenceProducesNothingToSend() {
        XCTAssertNil(VoiceTranscript.accepted(""))
        XCTAssertNil(VoiceTranscript.accepted("   "))
        XCTAssertNil(VoiceTranscript.accepted("\n\t  \n"))
    }

    /// The vacuity arm for the guard above.
    ///
    /// `accepted` returning `nil` for EVERYTHING would pass every assertion in
    /// `testSilenceProducesNothingToSend` — and would silently break voice
    /// input entirely while the suite stayed green. This is the leg that says
    /// the guard is a filter and not a wall.
    func testARealUtteranceSurvivesTheGuardTrimmed() {
        XCTAssertEqual(VoiceTranscript.accepted("restart the kitchen node"),
                       "restart the kitchen node")
        XCTAssertEqual(VoiceTranscript.accepted("  status  "), "status")
    }

    /// A transcript is not truncated, lowercased, or otherwise edited.
    ///
    /// The operator reviews what the DEVICE HEARD before they send it; an app
    /// that tidies the transcript is showing them something other than the
    /// thing that will be dispatched.
    func testTheTranscriptIsCarriedVerbatimApartFromEdgeWhitespace() {
        let messy = "Restart NODE-02, then tail the logs — 500 lines."
        XCTAssertEqual(VoiceTranscript.accepted("  \(messy)  "), messy)
    }

    // MARK: - the deferred arm, asserted as absent

    /// `/v1/stt` IS NOT BUILT, and this leg is what keeps it that way.
    ///
    /// The endpoint is mounted on the gateway and it egresses by construction:
    /// a real 1s 16kHz WAV through the real handler returned
    /// `500 "No Whisper API key found. Set GROQ_API_KEY or OPENAI_API_KEY."`,
    /// and `select_whisper_provider` chooses Groq or OpenAI. Building that arm
    /// would put operator audio on a third party's servers and falsify the
    /// `LAN BY DEFAULT · NO EGRESS` string in `Route.swift`.
    ///
    /// The leg carries TWO POSITIVE CONTROLS in the same invocation, because a
    /// zero-hit search over a mis-resolved path is indistinguishable from a
    /// clean absence — and this file's whole claim rests on a zero.
    func testNoUploadArmSurvivesInShippingSource() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ZeusTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Sources/ZeusApp")

        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        // CONTROL 1 — the enumeration found a real corpus, not an empty dir.
        XCTAssertGreaterThan(
            files.count, 20,
            "enumerated \(files.count) swift files — the path is wrong and "
                + "every absence claim below is a statement about nothing"
        )

        var corpus = ""
        for f in files { corpus += (try? String(contentsOf: f, encoding: .utf8)) ?? "" }

        // CONTROL 2 — the corpus contains a thing that MUST be there.
        XCTAssertTrue(
            corpus.contains("struct VoiceCapability"),
            "the corpus does not contain a symbol known to exist — the read "
                + "failed and the zeros below are meaningless"
        )

        // The subject. Note these needles are chosen to name the ARM, not the
        // topic: the doc comment in `Voice.swift` discusses the endpoint at
        // length, so a needle of "stt" would match the explanation for the
        // absence and report a false positive — the `grep -rlE 'Sheet|Alert'`
        // defect, which matched the identifiers it had just been named after.
        //
        // ⚠️ AND IT FIRED ON ITS OWN RATIONALE THE FIRST TIME IT RAN. The
        // original comment in `Voice.swift` spelled out the alias route in
        // full while explaining why the arm was not built — which put the
        // needle inside the file the leg was written to protect. Same defect
        // as `testNoModelVersionStringSurvivesInShippingSource` firing on the
        // comment that explained the removal of the model literals: A
        // PROHIBITION THAT EXEMPTS ITS OWN EXPLANATION IS NOT A PROHIBITION,
        // and the fix is to cite the coordinate rather than quote the string.
        for needle in ["multipart/form-data", "audio/transcriptions",
                       "boundary=", "httpBody = audio"] {
            XCTAssertFalse(
                corpus.contains(needle),
                "\(needle) is present in shipping source — the upload arm was "
                    + "built, and it egresses operator audio to Groq/OpenAI"
            )
        }
    }

    // MARK: - the meter

    /// Silence draws a still orb, and an empty buffer is not motion.
    ///
    /// The floor is the load-bearing half: room tone on a phone mic sits far
    /// above literal zero, so a meter mapping linearly from 0 would render an
    /// empty room as a live orb — a picture claiming to hear something.
    func testQuietAudioAndNoAudioBothReadAsStill() {
        XCTAssertEqual(VoiceMeter.level([]), 0,
                       "an empty buffer must not invent motion")
        XCTAssertEqual(VoiceMeter.level([0, 0, 0, 0]), 0,
                       "digital silence is still")

        // Room tone: below the floor, so still.
        let tone = [Float](repeating: 0.001, count: 512)
        XCTAssertEqual(VoiceMeter.level(tone), 0,
                       "room tone is below the floor and must not pulse")

        // NEG CONTROL — the floor is a floor, not a mute. A signal just above
        // it must move, or this leg would pass against a meter wired to 0.
        let audible = [Float](repeating: 0.05, count: 512)
        XCTAssertGreaterThan(VoiceMeter.level(audible), 0,
                             "a signal above the floor must register")
    }

    /// Louder input yields a higher level, and the range is clamped at 1.
    ///
    /// Monotonicity is the property the orb actually consumes: the renderer
    /// reads `level` into a displacement term, so a meter that is merely
    /// non-zero but unordered would animate without corresponding to speech.
    func testTheMeterIsMonotonicAndClampedToTheRendererRange() {
        let quiet  = VoiceMeter.level([Float](repeating: 0.02, count: 256))
        let mid    = VoiceMeter.level([Float](repeating: 0.10, count: 256))
        let loud   = VoiceMeter.level([Float](repeating: 0.24, count: 256))

        XCTAssertLessThan(quiet, mid, "level must rise with amplitude")
        XCTAssertLessThan(mid, loud, "level must rise with amplitude")

        // Clipping: full-scale and beyond both pin at 1, never above — the
        // renderer's displacement term is scaled by this and a value over 1
        // puts geometry outside the shape the tuning describes.
        XCTAssertEqual(VoiceMeter.level([Float](repeating: 1.0, count: 256)), 1)
        XCTAssertEqual(VoiceMeter.normalize(99), 1,
                       "an out-of-range RMS must clamp, not escape the range")

        // VACUITY — the three readings are genuinely distinct, so the
        // ordering above is not three equal values trivially satisfying `<`.
        XCTAssertNotEqual(quiet, loud)
    }

    /// RMS, not peak: one clipped sample must not pin the orb.
    ///
    /// A peak meter reads a single click as sustained speech for the whole
    /// buffer. This leg fails against `samples.map(abs).max()`, which is the
    /// mistake the implementation is written to avoid.
    func testOneLoudSampleDoesNotPinTheMeter() {
        var buffer = [Float](repeating: 0, count: 1024)
        buffer[0] = 1.0                       // a single full-scale click

        let level = VoiceMeter.level(buffer)
        XCTAssertLessThan(level, 0.5,
                          "a single clipped sample must not read as speech — "
                              + "this is peak-vs-RMS and peak fails here")

        // POS CONTROL — the same energy spread across the buffer DOES read
        // high, so the leg above is measuring distribution and not just
        // asserting that small numbers are small.
        let sustained = [Float](repeating: 0.3, count: 1024)
        XCTAssertGreaterThan(VoiceMeter.level(sustained), 0.5)
    }

    /// The tap feeds the meter, and it is the SAME buffer the recognizer gets.
    ///
    /// ⚠️ SOURCE LEG, and it has to be. `installTap`'s closure has no
    /// in-process observable: nothing in this target can start an
    /// `AVAudioEngine`, so a behavioural leg cannot witness the wire. A leg
    /// asserting only that `VoiceMeter.level` is correct would be a property of
    /// the TYPE and would stay green with the meter never called — the exact
    /// shape that let `icon: "doc"` survive a green suite in S5.
    ///
    /// So this slices the shipped `beginTap` body between two anchors and
    /// asserts the meter is reached inside it. VOID if either anchor moves.
    func testTheInstalledTapFeedsTheMeterFromTheRecognizersOwnBuffer() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Voice.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        let openAnchor  = "input.installTap("
        let closeAnchor = "engine.prepare()"

        guard let start = source.range(of: openAnchor),
              let end   = source.range(of: closeAnchor, range: start.upperBound ..< source.endIndex)
        else {
            return XCTFail(
                "VOID — an anchor moved (\(openAnchor) / \(closeAnchor)); this "
                    + "leg measured nothing and must not be read as a pass"
            )
        }
        let slice = String(source[start.upperBound ..< end.lowerBound])

        // The recognizer still receives the buffer — the meter is an ADDITION
        // to the existing wire, never a replacement for it.
        XCTAssertTrue(slice.contains("req?.append(buffer)"),
                      "the recognizer must still receive every buffer")

        // The meter is reached from inside the tap.
        XCTAssertTrue(slice.contains("VoiceMeter.level("),
                      "the installed tap does not feed the meter — the orb "
                          + "would pulse on a value nothing measures")

        // ONE capture, TWO readers: a second tap is a second aperture, and two
        // meters of one microphone can disagree.
        XCTAssertEqual(
            source.components(separatedBy: "installTap(").count - 1, 1,
            "exactly one tap may be installed"
        )

        // NEG CONTROL — the slice is a real slice and not the whole file.
        XCTAssertFalse(slice.contains("static func level("),
                       "the slice escaped its anchors")
    }

    /// Teardown zeroes the meter, so a dead microphone cannot draw a live orb.
    ///
    /// Source-level for the same reason as above: `stop()` touches the engine.
    /// The ORDER is the assertion — zeroing after the tap is removed races a
    /// renderer already holding the last live value.
    func testStopZeroesTheMeterBeforeItRemovesTheTap() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Voice.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        guard let stopRange = source.range(of: "func stop() {"),
              let zero      = source.range(of: "level = 0", range: stopRange.upperBound ..< source.endIndex),
              let removeTap = source.range(of: "removeTap(onBus: 0)", range: stopRange.upperBound ..< source.endIndex)
        else {
            return XCTFail("VOID — an anchor moved inside stop(); nothing measured")
        }

        XCTAssertLessThan(
            zero.lowerBound, removeTap.lowerBound,
            "the meter must be zeroed BEFORE the tap is removed, or a stale "
                + "level survives the microphone it described"
        )
    }
}
