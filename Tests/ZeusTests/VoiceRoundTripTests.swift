import XCTest
@testable import Zeus

// MARK: - the voice-finalize leg
//
// merakizzz on build 192: "Voice still doesn't work, I send a message but
// seems nothing ever gets recorded or sent." The capture was fine. The RESULT
// was discarded: `stop()` called `endAudio()` — which ASKS for the final
// transcription — and then `task?.cancel()` on the very next line, which threw
// the task away before that final could arrive. Only `isFinal` wrote
// `transcript`, so the stop path published nothing, silently.
//
// ⚠️ APERTURE, stated because it bounds every structural leg in this file.
// Nothing here drives `SFSpeechRecognizer`: constructing one in a unit-test
// process touches the real OS grant machinery, exactly as `VoiceTests` already
// records. What IS measured is the ORDERING and the WIRING in the shipping
// source — a census, in the same shape as `testStopZeroesTheMeterBefore...`.
// A census is proven only by a mutation that keeps the corpus COMPILING and
// makes the census itself red; a signature change would be build-dead.

final class VoiceFinalizeTests: XCTestCase {

    /// Comments stripped. 🔴 THIS LEG RED ON ITS OWN PROSE FIRST TIME OUT: the
    /// doc comment above the retention line in `Voice.swift` explains the
    /// `isFinal` gate in order to forbid it, so the raw-text census found the
    /// forbidden token in the sentence banning it. Same use-vs-mention defect
    /// `AttachCoherenceTests.codeOnly` was written for, arriving in the file
    /// where I'd just banked the rule. A source census must define its corpus
    /// as COMPILER-VISIBLE text before it counts anything — the filter is part
    /// of the instrument, not an afterthought.
    private static func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slash = line.range(of: "//") else { return line }
                return line[line.startIndex ..< slash.lowerBound]
            }
            .joined(separator: "\n")
    }

    private func voiceSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Voice.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertGreaterThan(text.count, 500, "VOID: Voice.swift did not load")
        return Self.codeOnly(text)
    }

    /// The defect itself: a stop that cancels before publishing.
    func testTheOperatorsStopPublishesBeforeItCancelsTheTask() throws {
        let source = try voiceSource()

        guard let stopRange = source.range(of: "func stop() {"),
              let close = source.range(of: "\n    }", range: stopRange.upperBound ..< source.endIndex)
        else {
            return XCTFail("VOID — `func stop() {` moved; this leg measured nothing")
        }
        let body = String(source[stopRange.upperBound ..< close.lowerBound])

        // POS control: the slice is the function we think it is.
        XCTAssertTrue(
            body.contains("endAudio()"),
            "VOID — the stop slice does not contain `endAudio()`, so it is not "
                + "the function this leg is named for"
        )

        // THE CLAIM. A publish must happen on the operator's stop path.
        XCTAssertTrue(
            body.contains("finish()"),
            "the operator's stop must FINALIZE — publish the retained reading "
                + "— or every utterance ended with the stop button is discarded "
                + "in silence, which is the defect merakizzz reported on 192"
        )

        // THE DEFECT'S OWN SPELLING, asserted ABSENT. `cancel()` beside
        // `endAudio()` in this function is precisely what threw the final away.
        XCTAssertFalse(
            body.contains("task?.cancel()"),
            "`stop()` must not cancel the recognition task directly — that is "
                + "the cancel-before-final bug. Teardown belongs after the "
                + "publish, inside `teardown()`"
        )
    }

    /// The fallback that makes the finalize possible at all.
    func testEveryPartialIsRetainedSoAStopHasSomethingToPublish() throws {
        let source = try voiceSource()

        guard let taskRange = source.range(of: "recognitionTask(with: req)"),
              let end = source.range(of: "nonisolated static func samples",
                                     range: taskRange.upperBound ..< source.endIndex)
        else {
            return XCTFail("VOID — the recognition-task anchor moved; nothing measured")
        }
        let slice = String(source[taskRange.upperBound ..< end.lowerBound])

        // POS control: the slice really is the callback, AND the strip left
        // real code behind — a `codeOnly` that ate the function body would
        // make every `XCTAssertFalse` below pass vacuously.
        XCTAssertTrue(
            slice.contains("bestTranscription"),
            "VOID — the recognition-task slice does not read a transcription"
        )
        XCTAssertTrue(
            slice.contains("result.isFinal"),
            "VOID — the surviving-code control is absent: `result.isFinal` is "
                + "live code in this callback, so a slice without it means the "
                + "strip removed code and every absence claim below is vacuous"
        )

        // THE CLAIM: the reading is retained on EVERY result, not only final.
        XCTAssertTrue(
            slice.contains("self.latest = result.bestTranscription.formattedString"),
            "every result — partial included — must be retained, or a stop "
                + "that arrives before the asynchronous final has nothing to "
                + "publish and the utterance is lost"
        )

        // And the retention must NOT be gated on `isFinal`: that gate is the
        // original defect, and an `if result.isFinal { latest = … }` spelling
        // would pass the assertion above while restoring the bug exactly.
        guard let assign = slice.range(of: "self.latest = result") else {
            return XCTFail("VOID — the retention line moved")
        }
        let beforeAssign = String(slice[slice.startIndex ..< assign.lowerBound])
        XCTAssertFalse(
            beforeAssign.contains("isFinal"),
            "the retention must not sit behind an `isFinal` gate — that gate IS "
                + "the discarded-transcript defect, and gating it here would "
                + "restore the bug while keeping this leg's first half green"
        )
    }

    /// An abort must not publish a half-heard sentence.
    func testAnErroredRecognitionPublishesNothing() throws {
        let source = try voiceSource()

        guard let abortRange = source.range(of: "private func abort() {"),
              let close = source.range(of: "\n    }", range: abortRange.upperBound ..< source.endIndex)
        else {
            return XCTFail("VOID — `abort()` moved; nothing measured")
        }
        let body = String(source[abortRange.upperBound ..< close.lowerBound])

        XCTAssertFalse(
            body.contains("transcript ="),
            "the abort path must not write `transcript` — a recognizer that "
                + "failed mid-utterance holds a PREFIX, and publishing it "
                + "would invent a shorter sentence the operator never finished"
        )
        XCTAssertTrue(
            body.contains("teardown()"),
            "VOID — abort no longer tears down, so this leg is not measuring "
                + "the abort path"
        )
    }
}

// MARK: - the narrator-on-reply leg
//
// merakizzz: "The orb should speak, it doesn't do it yet." `Narrator` wraps
// `AVSpeechSynthesizer` — on-device, free, already in the binary — and its
// ONLY production callers were `Commissioning.swift:500/502`. The orb narrated
// onboarding and went mute forever. No STT/TTS provider is needed in either
// direction: `SFSpeechRecognizer` in, `AVSpeechSynthesizer` out.

final class ReplyNarrationTests: XCTestCase {

    private func message(_ role: Message.Role,
                         _ text: String,
                         streaming: Bool = false) -> Message {
        Message(role: role, text: text, streaming: streaming)
    }

    func testTheOperatorsOwnWordsAreNeverSpokenBack() {
        let m = message(.user, "what is the node count")
        XCTAssertNil(
            ReplyNarration.nextToSpeak(messages: [m], spoken: []),
            "a user turn must never be narrated — speaking it back would make "
                + "a send sound like a reply"
        )
        // NEG contrast: the same text as an AGENT turn IS eligible, so the
        // refusal above is about the ROLE and not about the fixture.
        let agent = message(.agent, "what is the node count")
        XCTAssertNotNil(ReplyNarration.nextToSpeak(messages: [agent], spoken: []))
    }

    func testAStreamingReplyIsNotSpokenUntilItHasFinished() {
        let partial = message(.agent, "the node coun", streaming: true)
        XCTAssertNil(
            ReplyNarration.nextToSpeak(messages: [partial], spoken: []),
            "a streaming reply must not be narrated — the orb would speak a "
                + "PREFIX and fall silent mid-sentence"
        )
        let settled = message(.agent, "the node count is four")
        XCTAssertNotNil(ReplyNarration.nextToSpeak(messages: [settled], spoken: []))
    }

    func testAReplyIsSpokenOnceNoMatterHowOftenTheArrayRepublishes() {
        let reply = message(.agent, "four nodes are linked")
        guard let first = ReplyNarration.nextToSpeak(messages: [reply], spoken: []) else {
            return XCTFail("the first eligible reply must be offered")
        }
        XCTAssertEqual(first.id, reply.id)

        XCTAssertNil(
            ReplyNarration.nextToSpeak(messages: [reply], spoken: [reply.id]),
            "an already-spoken id must never be offered twice — `messages` "
                + "republishes on every token, and an un-deduplicated wire "
                + "restarts the utterance dozens of times per reply"
        )
    }

    func testAnEmptyReplyIsNotSpoken() {
        XCTAssertNil(
            ReplyNarration.nextToSpeak(messages: [message(.agent, "   ")], spoken: []),
            "a blank reply must not be narrated — the same empty-utterance "
                + "refusal `VoiceTranscript.accepted` makes on the way in"
        )
    }

    func testTheNewestEligibleReplyWins() {
        let older = message(.agent, "first answer")
        let newer = message(.agent, "second answer")
        XCTAssertEqual(
            ReplyNarration.nextToSpeak(messages: [older, newer], spoken: [])?.id,
            newer.id,
            "the newest eligible reply is the one to speak — a queue of stale "
                + "replies read in order would talk over the session"
        )
    }

    /// THE WIRING. The pure decision above is worth nothing if nothing calls
    /// `narrate()` outside commissioning — correct-but-unreachable, the defect
    /// class this app keeps finding. A source census, for the reason stated at
    /// the top of the file: a SwiftUI view cannot be observed in-process.
    func testAnAssistantReplyReachesANarrateCallerOutsideCommissioning() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp")

        let rootView = try String(
            contentsOf: root.appendingPathComponent("RootView.swift"), encoding: .utf8)

        // POS control: we are reading the file we think we are.
        XCTAssertTrue(
            rootView.contains("struct RootView"),
            "VOID — RootView.swift does not declare `RootView`"
        )

        XCTAssertTrue(
            rootView.contains("replyNarrator.narrate("),
            "an assistant reply must reach a `narrate()` caller OUTSIDE "
                + "`Commissioning.swift` — before this, the orb spoke only "
                + "during onboarding and went mute forever after"
        )
        XCTAssertTrue(
            rootView.contains("ReplyNarration.nextToSpeak("),
            "the narration must go through the guarded decision, not a raw "
                + "`messages.last` at the call site — the three refusals "
                + "(user turn, streaming prefix, already spoken) live there"
        )
        XCTAssertTrue(
            rootView.contains("onChange(of: session.messages)"),
            "the producer is the published `messages` array — `SessionEngine` "
                + "has no did-finish hook (the turn settles inside a private "
                + "`defer`), so this is the only observable completion surface"
        )

        // NEG control: a token that is in no source file.
        XCTAssertFalse(rootView.contains("zzqqNoSuchNarrationToken"))
    }

    /// The mute toggle must exist somewhere an operator can reach after
    /// onboarding — the commissioning one dies with its screen.
    func testTheMuteToggleIsReachableOutsideCommissioning() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp")

        let session = try String(
            contentsOf: dir.appendingPathComponent("SessionView.swift"), encoding: .utf8)
        let rootView = try String(
            contentsOf: dir.appendingPathComponent("RootView.swift"), encoding: .utf8)

        XCTAssertTrue(
            session.contains("onToggleNarration"),
            "the SESSION stage must carry the narration toggle — it is the "
                + "screen where the orb speaks, and `Commissioning`'s toggle "
                + "is destroyed with its view after onboarding"
        )
        XCTAssertTrue(
            session.contains("speaker.slash"),
            "VOID — the muted glyph is absent, so the control above is not "
                + "the speaker toggle this leg is named for"
        )
        XCTAssertTrue(
            rootView.contains("replyNarrator.voiceOn.toggle()"),
            "the toggle must WRITE the narrator that actually speaks — a "
                + "glyph that flips its own picture and changes nothing is "
                + "the dead-control class this app retires"
        )
    }

    /// The preference is about the DEVICE, not one screen.
    func testTheNarrationPreferenceSurvivesTheScreenItWasSetOn() {
        let name = "zeus.tests.narration"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)

        XCTAssertTrue(
            NarrationPreference.isOn(suite),
            "voice defaults ON — a narrator that defaults silent makes the "
                + "speaking orb look broken on a fresh install"
        )

        NarrationPreference.set(false, suite)
        XCTAssertFalse(
            NarrationPreference.isOn(suite),
            "a mute set on one screen must be readable from another — the "
                + "operator expressed a preference about the device"
        )

        NarrationPreference.set(true, suite)
        XCTAssertTrue(NarrationPreference.isOn(suite))
        suite.removePersistentDomain(forName: name)
    }
}
