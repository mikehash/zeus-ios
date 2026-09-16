import XCTest
@testable import Zeus

/// PHASE 3 — the SESSION screen rebuilt voice-first.
///
/// Three classes of leg live here, and they are separated on purpose because
/// they have different apertures:
///
///   1. PURE DERIVATIONS (`stageLine`, `stageLevel`, `attachEnabled`) —
///      behavioural, exercisable without a rendered view.
///   2. SOURCE SLICES — the only instrument that can witness whether a `View`
///      body READS a derivation. This target has no ViewInspector and a
///      SwiftUI body is not observable in-process, so a leg asserting a
///      derivation is CORRECT says nothing about the view calling it. That
///      distinction cost a green suite in S5 (`icon: "doc"` survived a leg
///      asserting `RecallHit.icon` differed by kind) and is now the fifth
///      arrival of the same class; it is instrumented up front here.
///   3. CENSUSES over `codeOnly` source — comments stripped, because
///      `SessionView` DOCUMENTS the fabrications it refuses (the invented
///      filename, the `FILE INDEXED` toast) and a raw-text census would read
///      its own subject's explanation as an occurrence.
@MainActor
final class SessionStageTests: XCTestCase {

    // MARK: - The stage line

    /// Ambient with nothing heard: the invitation, naming the control by the
    /// label the button carries.
    func testTheAmbientStageInvitesTheOperatorToTheControlByName() {
        XCTAssertEqual(SessionView.stageLine(voiceState: .idle, partial: nil),
                       "TAP COMMS TO TRANSMIT")
    }

    /// A mic state that has something to say WINS over the invitation — a
    /// denial is fixable and inviting a tap that cannot work is the silent
    /// non-action this screen exists to retire.
    func testAMicStateOutranksTheInvitation() {
        XCTAssertEqual(SessionView.stageLine(voiceState: .denied, partial: nil),
                       "MIC DENIED — ENABLE IN SETTINGS")
        XCTAssertEqual(SessionView.stageLine(voiceState: .unavailable, partial: nil),
                       "VOICE UNAVAILABLE ON THIS DEVICE")
        // assert_ne's twin: the two spellings are DIFFERENT, so a leg that
        // only ever names one value cannot be satisfied by a constant.
        XCTAssertNotEqual(SessionView.stageLine(voiceState: .denied, partial: nil),
                          SessionView.stageLine(voiceState: .idle, partial: nil))
    }

    /// A partial outranks both — it is what the operator is saying RIGHT NOW,
    /// and the whole reason the stage exists is to show it before it commits.
    func testAPartialOutranksEveryStatusString() {
        XCTAssertEqual(SessionView.stageLine(voiceState: .listening, partial: "call ali at six"),
                       "call ali at six")
    }

    /// Whitespace is not a partial. A recognizer emitting `"  "` must not blank
    /// the line into a stage with no words on it at all.
    func testWhitespaceIsNotAPartial() {
        XCTAssertEqual(SessionView.stageLine(voiceState: .listening, partial: "   "),
                       "LISTENING — TAP TO STOP")
    }

    // MARK: - The stage level

    /// The METERED arm, clamped at the seam. `DeviceOrb.level` documents
    /// `0...1` and a renderer argument may not inherit a producer's range.
    func testTheMeteredArmIsClampedAtTheStageSeam() {
        XCTAssertEqual(SessionView.stageLevel(state: .ambient, voiceState: .listening, micLevel: 0.42),
                       0.42, accuracy: 0.0001)
        XCTAssertEqual(SessionView.stageLevel(state: .ambient, voiceState: .listening, micLevel: 9.0), 1.0)
        XCTAssertEqual(SessionView.stageLevel(state: .ambient, voiceState: .listening, micLevel: -3.0), 0.0)
    }

    /// OFF the tap, the value is the two-valued constant over a real reading —
    /// and it must NOT be the mic, because nothing is metering one. A stage
    /// that showed `micLevel` while the tap was removed would draw a
    /// listening orb over a dead microphone.
    func testTheUnmeteredArmIgnoresTheMicEntirely() {
        for phase in [AgentState.ambient, .thinking] {
            XCTAssertEqual(SessionView.stageLevel(state: phase, voiceState: .idle, micLevel: 0.9), 0.2,
                           "an idle tap must not publish an amplitude: \(phase)")
        }
        for phase in [AgentState.listening, .responding] {
            XCTAssertEqual(SessionView.stageLevel(state: phase, voiceState: .idle, micLevel: 0.9), 0.7)
        }
        // Floor: the metered arm DOES read it, so 0.2/0.7 are not constants.
        XCTAssertEqual(SessionView.stageLevel(state: .ambient, voiceState: .listening, micLevel: 0.55),
                       0.55, accuracy: 0.0001)
    }

    // MARK: - The attach arm

    /// TERMINAL, not link-conditioned. The verb does not exist (census below),
    /// so no tap, no retry and no connectivity change can produce it — exactly
    /// as `VoiceState.unavailable` is terminal for the same stated reason.
    func testAttachIsTerminallyDisabledAndSaysWhy() {
        XCTAssertFalse(SessionView.attachEnabled,
                       "no file ingest exists on this build; an armed paperclip is a lie with a tap target")
        XCTAssertTrue(SessionView.attachReason.contains("NO FILE INGEST"),
                      "the reason must name the missing VERB, not a link state")
        XCTAssertFalse(SessionView.attachReason.contains("UNREACHABLE"),
                       "NEG: 'unreachable' asserts the path exists and is merely down")
    }

    // MARK: - Source slices — does the VIEW read the derivations?

    /// MUT: replace the stage orb's `level:` with a literal and this reds.
    /// A leg asserting `stageLevel` is correct would stay green — the S5
    /// lesson, applied before the mutation rather than after it.
    func testTheStageOrbReadsTheMeteredDerivationAndNotALiteral() throws {
        let slice = try Self.slice(from: "private var stage: some View {",
                                   to: "private var stageControls: some View {")
        XCTAssertTrue(slice.contains("SessionView.stageLevel("),
                      "POS: the stage body must call the derivation")
        XCTAssertTrue(slice.contains("micLevel: micLevel"),
                      "POS: the live meter must reach the derivation")
        XCTAssertTrue(slice.contains("SessionView.stageLine("),
                      "POS: the status line is derived, not inlined")
        XCTAssertFalse(slice.contains("zzzNoSuchStageToken"),
                       "NEG control: the slice did not escape its anchors")
    }

    /// The controls row: COMMS wired to the one `VoiceInput`, attach dead by
    /// the NAMED derivation.
    ///
    /// The second half is the load-bearing one. `LinkMonitor` is reachable
    /// from this screen's owner and `voiceState` is in scope here, so
    /// conditioning attach on either costs nothing and is a live temptation —
    /// and it would assert the ingest path EXISTS and is merely unavailable.
    func testTheControlsRowWiresCommsAndKillsAttachByName() throws {
        let slice = try Self.slice(from: "private var stageControls: some View {",
                                   to: "// MARK: - Transcript")
        XCTAssertTrue(slice.contains("action: onVoice"),
                      "POS: COMMS runs the one VoiceInput's toggle")
        XCTAssertTrue(slice.contains("enabled: SessionView.attachEnabled"),
                      "attach must read the named derivation, so a leg can refuse a conditioned spelling")
        XCTAssertFalse(slice.contains("link."),
                       "NEG: attach must not be conditioned on link state — the verb is absent, not down")
        XCTAssertFalse(slice.contains("zzzNoSuchControl"),
                       "NEG control: the slice did not escape its anchors")
    }

    /// The stage is the DEFAULT body and the transcript is the toggle over it.
    /// MUT: flip `showLog`'s initial value and this reds.
    func testTheVoiceStageIsTheDefaultBodyAndTheLogIsSecondary() throws {
        let body = try Self.sessionViewSource()
        XCTAssertTrue(Self.codeOnly(body).contains("@State private var showLog: Bool = false"),
                      "the log is secondary — a voice-first screen does not open on its transcript")
        XCTAssertTrue(Self.codeOnly(body).contains("@State private var showKeyboard: Bool = false"),
                      "the keyboard is summoned, not resident")
        let slice = try Self.slice(from: "var body: some View {", to: "private func applyVoiceCommit")
        XCTAssertTrue(slice.contains("if showLog {"), "POS: the body branches on the toggle")
        XCTAssertTrue(slice.contains("stage"), "POS: the stage is an arm of that branch")
    }

    // MARK: - Auto-send: voice auto, text explicit

    /// THE ASYMMETRY, pinned on both arms in one leg so neither can drift
    /// alone.
    ///
    /// Voice commits without a second tap (jsx:447); the keyboard keeps
    /// explicit send (jsx:1001-1003). And the voice path calls `send()` — the
    /// SAME function the SEND button and the return key call — rather than
    /// reaching past it to `onSend`, so `canSend`'s refusal of a disarmed
    /// composer applies identically. A path that assembled its own turn would
    /// bypass the one decision this screen has.
    func testVoiceAutoCommitsThroughTheProductionSendAndTextDoesNot() throws {
        let code = Self.codeOnly(try Self.sessionViewSource())

        XCTAssertTrue(code.contains("private func applyVoiceCommit()"),
                      "POS: the voice arm exists as its own named path")
        let slice = Self.codeOnly(
            try Self.slice(from: "private func applyVoiceCommit() {",
                           to: "private func applyPrefill() {")
        )
        XCTAssertTrue(slice.contains("send()"),
                      "the voice arm must invoke the production send, not assemble its own turn")
        XCTAssertFalse(slice.contains("onSend("),
                       "NEG: reaching past send() bypasses canSend and commits a turn the UI refuses")
        XCTAssertTrue(slice.contains("voiceCommit.wrappedValue = nil"),
                      "single-shot: the binding clears BEFORE the send, so the re-render cannot re-enter")

        // The TEXT arm, same invocation: the composer's send stays behind an
        // explicit gesture. `applyPrefill` must NOT gain an unconditional
        // send — its only send is the `#if DEBUG` capture seam.
        let prefill = try Self.slice(from: "private func applyPrefill() {", to: "// MARK: - Header")
        // NOT stripped: this leg's subject IS the `#if DEBUG` directive, which
        // is code, and its send-count filter already excludes comment lines.
        XCTAssertTrue(prefill.contains("#if DEBUG"),
                      "POS: the deep-link arm's only send stays debug-gated")
        let prefillSends = prefill.split(separator: "\n").map(String.init).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("//") && !t.hasPrefix("///") && t.contains("send()")
        }
        XCTAssertEqual(prefillSends.count, 1,
                       "the deep-link arm has exactly one send and it is the DEBUG seam; found \(prefillSends)")
    }

    /// 🔴 THE SECURITY LEG. Voice and deep links must be DIFFERENT bindings.
    ///
    /// Auto-sending `prefill` would not add a voice behaviour — it would add a
    /// release auto-send to every `zeus://` URL any other app on the phone can
    /// fire, the threat `LaunchArgs.swift:177` names and the reason the
    /// capture seam is `#if DEBUG`. Two channels make the wrong dispatch
    /// unrepresentable.
    func testTheSpokenChannelIsNotTheDeepLinkChannel() throws {
        let code = Self.codeOnly(try Self.sessionViewSource())
        XCTAssertTrue(code.contains("var voiceCommit: Binding<String?>"),
                      "POS: the spoken channel is its own binding")
        XCTAssertTrue(code.contains("var prefill: Binding<String?>"),
                      "POS control: the deep-link channel still exists")
        XCTAssertNotEqual("voiceCommit", "prefill")

        // The auto-committing path must read the SPOKEN binding only.
        //
        // 🔴 `codeOnly` ON THE SLICE, and it cost a red leg to learn the
        // second time: this slice runs to the next declaration, so it
        // CONTAINS `applyPrefill`'s doc comment — which names `prefill` in
        // prose, exactly as `HomeView` named the verbs it does not have. A
        // slice is a corpus like any other, so the use-vs-mention strip
        // applies to it and not only to whole-file censuses.
        let slice = Self.codeOnly(
            try Self.slice(from: "private func applyVoiceCommit() {", to: "private func applyPrefill() {")
        )
        XCTAssertTrue(slice.contains("voiceCommit.wrappedValue"),
                      "VOID: the strip left no code — the NEG below would pass on an empty bucket")
        XCTAssertFalse(slice.contains("prefill"),
                       "NEG: the auto-send arm must never read the deep-link channel")

        // And the owner must route the transcript to the spoken channel.
        let root = Self.codeOnly(try Self.source("RootView.swift"))
        XCTAssertTrue(root.contains("voiceCommit = new"),
                      "POS: RootView routes the transcript to the spoken channel")
        XCTAssertFalse(root.contains("pendingPrompt = new"),
                       "NEG: the transcript must not land on the deep-link binding")
    }

    // MARK: - Census: nothing on this screen claims a file was read

    /// The prototype's attach sheet fabricates `CAPTURE-0142.JPG`, toasts
    /// `FILE INDEXED — SESSION CONTEXT` and appends "Received X — indexed to
    /// session context". None of it is transcribed, and none of the ingest
    /// verbs exist anywhere in the app.
    ///
    /// Censused over `codeOnly` because this file DOCUMENTS the refusal in
    /// prose — a raw-text census would read the explanation as the defect.
    func testNoFabricatedFilenameOrIndexClaimIsReachable() throws {
        let code = Self.codeOnly(try Self.allSourceText())

        for fabrication in ["CAPTURE-0142", "IMG-8821", "BLUEPRINT-R2",
                            "FILE INDEXED", "indexed to session context"] {
            XCTAssertEqual(Self.count(of: fabrication, in: code), 0,
                           "NEG: '\(fabrication)' asserts a file was read and indexed; nothing opens a file")
        }
        for verb in ["PHPicker", "UIImagePickerController", "fileImporter",
                     "documentPicker", "PhotosPicker"] {
            XCTAssertEqual(Self.count(of: verb, in: code), 0,
                           "NEG: '\(verb)' would mean the ingest path exists — then attach must stop being terminal")
        }
        // POS control in the SAME invocation, a code token: proves the strip
        // left real code to count, so the zeros are absences and not an
        // empty bucket.
        XCTAssertGreaterThan(Self.count(of: "SessionView.attachEnabled", in: code), 0,
                             "VOID: the code corpus did not survive the comment strip")
    }

    // MARK: - Helpers

    private static func count(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// Comments stripped. See `HomeControlsTests.codeOnly` for the incident
    /// that bought this: a census whose corpus includes prose cannot tell a
    /// use from a mention, and the sharper the doc comment the redder the leg.
    private static func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slash = line.range(of: "//") else { return line }
                return line[line.startIndex ..< slash.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ZeusTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent(relative)
    }

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: sourceURL("Sources/ZeusApp/\(name)"), encoding: .utf8)
    }

    private static func sessionViewSource() throws -> String {
        try source("SessionView.swift")
    }

    private static func allSourceText() throws -> String {
        let fm = FileManager.default
        var text = ""
        for dir in ["Sources/ZeusApp", "Sources/ZeusCoreFFI"] {
            guard let e = fm.enumerator(at: sourceURL(dir), includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        XCTAssertGreaterThan(text.count, 10_000, "VOID: the source corpus did not load")
        return text
    }

    /// VOID rather than false-pass when an anchor moves — an instrument that
    /// silently measures the whole file is worse than one that reds.
    private static func slice(from open: String, to close: String) throws -> String {
        let text = try sessionViewSource()
        guard let start = text.range(of: open),
              let end = text.range(of: close, range: start.upperBound ..< text.endIndex)
        else {
            XCTFail("VOID — an anchor moved (\(open) … \(close)); this leg measured nothing")
            return ""
        }
        return String(text[start.upperBound ..< end.lowerBound])
    }
}
