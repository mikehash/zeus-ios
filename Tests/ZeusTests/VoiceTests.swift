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
}
