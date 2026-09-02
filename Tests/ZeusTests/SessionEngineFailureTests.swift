import XCTest
@testable import Zeus

/// Failure legs for the session loop.
///
/// Written while `UnconfiguredTransport` is the ONLY transport — i.e. while the
/// error path is the path that runs on every send. The day a real transport
/// lands, `NO TRANSPORT` stops firing and this becomes the hardest path in the
/// engine to reach; these legs are cheap today and expensive then, which is the
/// whole reason they exist now rather than after M5.
///
/// Every leg asserts the *terminal* state as well as the visible one. A turn
/// that surfaces the right text but leaves `streaming == true` is a stuck caret
/// on screen, and no assertion about message text can see it.

// MARK: - Controllable transports

/// Yields the given deltas, then finishes — cleanly or by throwing.
private struct ScriptedTransport: SessionTransport {
    let frames: [SessionFrame]
    let thrown: Error?

    func stream(prompt: String) -> AsyncThrowingStream<SessionFrame, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for d in frames {
                    continuation.yield(d)
                    await Task.yield()
                }
                continuation.finish(throwing: thrown)
            }
        }
    }
}

/// Never finishes. The only way out of a turn on this transport is cancellation,
/// so it is the instrument that proves the `defer` runs on the cancel path.
private struct HangingTransport: SessionTransport {
    func stream(prompt: String) -> AsyncThrowingStream<SessionFrame, Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.token("partial"))
                // Deliberately never finished.
            }
        }
    }
}

private enum TestError: LocalizedError {
    case midstream
    var errorDescription: String? { "MIDSTREAM FAILURE" }
}

// MARK: -

@MainActor
final class SessionEngineFailureTests: XCTestCase {

    /// Drains the main-actor queue until `predicate` holds or the budget expires.
    /// Bounded so a hang fails the leg instead of hanging the suite.
    private func settle(_ label: String,
                        _ predicate: () -> Bool,
                        file: StaticString = #filePath,
                        line: UInt = #line) async {
        for _ in 0..<5000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("never settled: \(label)", file: file, line: line)
    }

    /// Waits for a turn to REACH ITS TERMINAL STATE.
    ///
    /// 🔴 Do not spell this as `state == .ambient`. `.ambient` is the INITIAL
    /// state, so that predicate is satisfied before the turn's `Task` has run a
    /// single line — it is true by construction, returns instantly, and every
    /// assertion after it reads a transcript that does not exist yet. Measured:
    /// four legs "passed the wait" and then indexed out of range.
    ///
    /// The terminal condition must be one the engine can only reach by having
    /// RUN: the agent slot exists, its caret is cleared, and the state has
    /// returned to ambient. The count is what makes it non-vacuous.
    private func awaitTurn(_ engine: SessionEngine,
                           slots: Int,
                           file: StaticString = #filePath,
                           line: UInt = #line) async {
        await settle("turn reaches \(slots) slots, settled",
                     { engine.messages.count == slots
                         && !(engine.messages.last?.streaming ?? true)
                         && engine.state == .ambient },
                     file: file, line: line)
    }

    // MARK: The default build — no wire

    /// The leg that is free today. `UnconfiguredTransport` throws before any
    /// delta arrives, so the agent slot is EMPTY when `fail` runs — this is the
    /// `existing.isEmpty` arm, and it must produce the reason alone with no
    /// leading blank lines.
    func testUnconfiguredTransportSurfacesReasonAndSettles() async {
        let engine = SessionEngine(transport: UnconfiguredTransport(), seed: [])
        engine.send("status")

        await awaitTurn(engine, slots: 2)

        XCTAssertEqual(engine.messages.count, 2)
        XCTAssertEqual(engine.messages[0].role, .user)

        let agent = engine.messages[1]
        XCTAssertEqual(agent.role, .agent)
        XCTAssertEqual(agent.text, TransportError.unconfigured.errorDescription)
        XCTAssertFalse(agent.text.hasPrefix("\n"), "empty-slot arm must not lead with a separator")
        XCTAssertFalse(agent.streaming, "caret must be cleared on the error path")
        XCTAssertEqual(engine.state, .ambient)
    }

    /// The reason must NAME the absence of a wire rather than reading as a
    /// network fault. Pinned against the string, because the distinction is the
    /// entire point of `.unconfigured` existing as its own case.
    func testUnconfiguredReasonIsAbsenceNotFailure() {
        let reason = TransportError.unconfigured.errorDescription ?? ""
        XCTAssertTrue(reason.contains("NO TRANSPORT"))
        XCTAssertTrue(reason.contains("nothing is listening"))
        XCTAssertNotEqual(reason, "", "a LocalizedError with no description is a silent failure")
    }

    // MARK: Partial arrival then failure

    /// A half-arrived answer is data. The engine must KEEP the accumulated text
    /// and append the reason beneath it — the non-empty arm of `fail`, which the
    /// unconfigured leg above can never reach.
    func testMidstreamFailureKeepsAccumulatedTextAndAppendsReason() async {
        let engine = SessionEngine(
            transport: ScriptedTransport(frames: [.token("All "), .token("systems ")], thrown: TestError.midstream),
            seed: [])
        engine.send("status")

        await awaitTurn(engine, slots: 2)

        let agent = engine.messages[1]
        XCTAssertTrue(agent.text.hasPrefix("All systems "), "accumulated deltas discarded")
        XCTAssertTrue(agent.text.hasSuffix("MIDSTREAM FAILURE"))
        XCTAssertTrue(agent.text.contains("\n\n"), "reason must be separated, not concatenated")
        XCTAssertFalse(agent.streaming)
        XCTAssertEqual(engine.state, .ambient)
    }

    /// Vacuity guard for the leg above: the two arms of `fail` must produce
    /// DIFFERENT text. If a refactor collapses them, both legs still pass on
    /// their own assertions and only this one fails.
    func testEmptyAndNonEmptyFailureArmsDiffer() async {
        let bare = SessionEngine(transport: UnconfiguredTransport(), seed: [])
        bare.send("x")
        await awaitTurn(bare, slots: 2)

        let partial = SessionEngine(
            transport: ScriptedTransport(frames: [.token("text")], thrown: TransportError.unconfigured),
            seed: [])
        partial.send("x")
        await awaitTurn(partial, slots: 2)

        XCTAssertNotEqual(bare.messages[1].text, partial.messages[1].text,
                          "same error, different slot state, must not render identically")
    }

    // MARK: Clean completion

    /// The control. Without it, every assertion above is satisfiable by an
    /// engine that fails unconditionally.
    func testCleanStreamCompletesWithoutError() async {
        let engine = SessionEngine(
            transport: ScriptedTransport(frames: [.token("nominal")], thrown: nil), seed: [])
        engine.send("status")

        await awaitTurn(engine, slots: 2)

        XCTAssertEqual(engine.messages[1].text, "nominal")
        XCTAssertFalse(engine.messages[1].streaming)
    }

    // MARK: Cancellation — the third exit path

    /// Invariant 2 on the path no happy-path check reaches. The transport never
    /// finishes, so the ONLY thing that can clear the caret is the `defer`.
    func testCancelClearsCaretAndReturnsToAmbient() async {
        let engine = SessionEngine(transport: HangingTransport(), seed: [])
        engine.send("status")

        await settle("stream opened") { engine.messages.count == 2 }
        engine.cancelTurn()
        await settle("cancelled turn settles") { !engine.messages[1].streaming && engine.state == .ambient }

        XCTAssertFalse(engine.messages[1].streaming, "orphaned caret: defer did not run on cancel")
    }

    /// Invariant 3. A second send while a turn hangs must cancel the first, so
    /// the transcript can never hold two streaming agent slots.
    func testSecondSendCancelsFirstTurn() async {
        let engine = SessionEngine(transport: HangingTransport(), seed: [])
        engine.send("first")
        await settle("first turn opened") { engine.messages.count == 2 }

        engine.send("second")
        // 🔴 `messages.count == 4` is reached by the SYNCHRONOUS prefix of
        // `send` — the user append — before the cancelled predecessor's `defer`
        // has run. Measured: 2 of 6 clean-DerivedData runs read TWO live carets
        // through that window. The terminal condition must name the thing only
        // the predecessor's teardown can produce: its caret cleared.
        await settle("predecessor settled") {
            engine.messages.count == 4 && !engine.messages[1].streaming
        }

        let streaming = engine.messages.filter { $0.streaming }
        XCTAssertEqual(streaming.count, 1, "two concurrent streams: \(streaming.count) carets live")
    }

    // MARK: Refusal

    /// Refused at the engine, not at the button — so the guard holds for every
    /// caller, including ones the view does not own.
    func testWhitespacePromptIsRefusedAtTheEngine() async {
        let engine = SessionEngine(transport: UnconfiguredTransport(), seed: [])
        engine.send("   \n\t ")
        await Task.yield()

        XCTAssertTrue(engine.messages.isEmpty, "whitespace prompt produced a turn")
        XCTAssertEqual(engine.state, .ambient)
    }

    /// Positive control for the refusal leg: the same engine DOES accept a real
    /// prompt. Without it, `messages.isEmpty` is also satisfied by an engine
    /// that refuses everything.
    func testNonEmptyPromptIsAccepted() async {
        let engine = SessionEngine(transport: UnconfiguredTransport(), seed: [])
        engine.send("  status  ")
        await awaitTurn(engine, slots: 2)

        XCTAssertEqual(engine.messages.first?.text, "status", "prompt must be trimmed, not raw")
    }
}

// MARK: - Frame routing
//
// THESE ARMS ARE NEW AND THE PRE-EXISTING 49 LEGS ARE BLIND TO THEM BY
// CONSTRUCTION. Every leg above asserts the TEXT path, so together they prove
// the frame cut PRESERVED prose and say exactly nothing about telemetry.
// 49/49 is not coverage of the enum; these legs are.

@MainActor
final class SessionFrameRoutingTests: XCTestCase {

    private func drain(_ engine: SessionEngine) async {
        for _ in 0..<200 {
            await Task.yield()
            if engine.state == .ambient && engine.messages.last?.streaming == false { return }
        }
    }

    /// The defect the frame cut exists to prevent: a tool invocation rendered
    /// as agent speech. Before the cut the fold was a bare `+=`, so EVERY frame
    /// became transcript text.
    func testTelemetryFramesNeverEnterTheTranscript() async {
        let engine = SessionEngine(
            transport: ScriptedTransport(frames: [
                .toolStart(name: "shell"),
                .iteration(2),
                .toolEnd(name: "shell", output: "ok"),
                .token("done."),
            ], thrown: nil), seed: [])
        engine.send("go")
        await drain(engine)

        let text = engine.messages.last?.text ?? ""
        XCTAssertEqual(text, "done.", "telemetry leaked into the transcript")
        XCTAssertFalse(text.contains("shell"), "tool name rendered as agent speech")
        XCTAssertFalse(text.contains("iteration"), "progress frame rendered as speech")
    }

    /// The other half: telemetry is not discarded either. Dropping it would
    /// also pass the leg above, so both directions are asserted.
    func testTelemetryFramesAreRecordedAsActivity() async {
        let engine = SessionEngine(
            transport: ScriptedTransport(frames: [
                .toolStart(name: "shell"),
                .toolEnd(name: "shell", output: "exit 1"),
                .token("x"),
            ], thrown: nil), seed: [])
        engine.send("go")
        await drain(engine)

        XCTAssertEqual(engine.activity.count, 3, "activity dropped frames")
        XCTAssertEqual(engine.activity.map(\.frame),
                       [.toolStart(name: "shell"),
                        .toolEnd(name: "shell", output: "exit 1"),
                        .token("x")],
                       "activity did not preserve arrival order or identity")
    }

    /// A failed tool must be distinguishable from a successful one. Collapsing
    /// `ok` would make both render identically to the operator.
    func testToolFailureIsDistinguishableFromToolSuccess() {
        let good = SessionActivity(.toolEnd(name: "shell", output: "ok")).label
        let bad  = SessionActivity(.toolEnd(name: "shell", output: "exit 1")).label
        XCTAssertNotEqual(good, bad, "a failed tool reads identically to a successful one")
    }

    /// An in-band `error` frame is the turn's outcome — it must reach the
    /// transcript, not only the side channel, or the reply ends mid-sentence
    /// and reads as the model choosing silence.
    func testInBandErrorFrameSurfacesInTheTranscript() async {
        let engine = SessionEngine(
            transport: ScriptedTransport(frames: [
                .token("partial "),
                .failure("model refused"),
            ], thrown: nil), seed: [])
        engine.send("go")
        await drain(engine)

        let text = engine.messages.last?.text ?? ""
        XCTAssertTrue(text.hasPrefix("partial "), "accumulated prose discarded")
        XCTAssertTrue(text.contains("model refused"), "agent error not surfaced")
        XCTAssertTrue(text.contains("AGENT ERROR"), "agent failure not named as such")
        XCTAssertEqual(engine.messages.last?.streaming, false, "caret left spinning")
    }

    /// An agent failure and a transport failure are different repairs. If these
    /// two sentences were equal the operator would check the network for a
    /// model fault.
    func testAgentFailureIsNotATransportFailure() {
        let agent = TransportError.agentFailed(reason: "boom").errorDescription ?? ""
        let wire  = TransportError.unreachable(host: "h", detail: "boom").errorDescription ?? ""
        XCTAssertNotEqual(agent, wire)
        XCTAssertTrue(agent.contains("wire is healthy"), "agent error blames the wire")
    }

    /// `.thinking` is prose but not ANSWER prose — it belongs to state, not to
    /// the transcript body.
    func testThinkingIsNotTranscriptText() {
        XCTAssertNil(SessionFrame.thinking("reasoning").transcriptText)
        XCTAssertEqual(SessionFrame.token("hi").transcriptText, "hi")
    }

    // MARK: - `done` is the whole-turn authority (①·b)

    /// The streaming path. `done.text` REPLACES the accumulated tokens, so a
    /// producer that folds the same bytes yields a NO-OP — not a doubling.
    /// This is the leg that fails if `done` is ever appended.
    func testDoneReplacesRatherThanAppendsOnTheStreamingPath() async {
        let engine = SessionEngine(
            transport: ScriptedTransport(frames: [
                .token("hello "), .token("world"), .done("hello world"),
            ], thrown: nil), seed: [])
        engine.send("go")
        await drain(engine)

        XCTAssertEqual(engine.messages.last?.text, "hello world",
                       "done.text was appended to the tokens instead of replacing them")
    }

    /// The no-token path — ASSERTED UPSTREAM, not hypothetical: `inbox.rs:1098`
    /// panics if a `Token` arrives before the `Done`. Discarding `done.text`
    /// here leaves the transcript EMPTY on a successful turn.
    func testDoneCarriesTheReplyWhenNoTokenStreamed() async {
        let engine = SessionEngine(
            transport: ScriptedTransport(frames: [
                .done("the entire reply"),
            ], thrown: nil), seed: [])
        engine.send("go")
        await drain(engine)

        XCTAssertEqual(engine.messages.last?.text, "the entire reply",
                       "done.text discarded — transcript empty on a successful turn")
    }

    /// The `agent_loop.rs:2538` divergence, where the tokens and the return
    /// value come from DIFFERENT producers, and the `:2543` stall — the 90s
    /// per-CHUNK idle bound, which breaks the token loop by design while the
    /// JoinHandle resolves with the COMPLETE text and the agent returns Ok.
    /// That is `gateway.rs:4688`, not the `:4690` whole-handler timeout: the
    /// two are different bounds at different layers and only this one lands in
    /// the Ok arm. Replace is a REPAIR here; the rule "discard done.text if any
    /// token arrived" would keep the truncation.
    func testDoneRepairsATruncatedTokenStream() async {
        let engine = SessionEngine(
            transport: ScriptedTransport(frames: [
                .token("partial"), .done("partial answer, completed"),
            ], thrown: nil), seed: [])
        engine.send("go")
        await drain(engine)

        XCTAssertEqual(engine.messages.last?.text, "partial answer, completed",
                       "a stalled token stream was not repaired by the authority")
    }

    /// `.done` must NOT be routed through `transcriptText`: that property is
    /// the ACCUMULATE path, and accumulating the authority is the doubling.
    /// Asserted against `.token` in the same call so a dead property cannot
    /// pass this leg vacuously.
    func testDoneIsNotAccumulatedProse() {
        XCTAssertNil(SessionFrame.done("whole reply").transcriptText)
        XCTAssertEqual(SessionFrame.token("hi").transcriptText, "hi")
    }

    /// `tool_end` carries the wire's `output`, not a fabricated `ok`. Pins the
    /// payload to the bytes rather than to a Swift-constructed boolean.
    func testToolEndSurfacesTheOutputItWasGiven() {
        let label = SessionActivity(.toolEnd(name: "shell", output: "exit 1")).label
        XCTAssertTrue(label.contains("exit 1"), "tool output dropped from the activity")
        XCTAssertTrue(label.contains("shell"), "tool name dropped from the activity")
    }

    /// All seven wire names have a representation. A count, so an eighth name
    /// arriving from the gateway has somewhere to fail loudly.
    func testAllSevenWireNamesHaveDistinctLabels() {
        let all: [SessionFrame] = [
            .token("a"), .thinking("b"), .toolStart(name: "c"),
            .toolEnd(name: "d", output: "out"), .iteration(1), .done("f"), .failure("e"),
        ]
        let labels = Set(all.map { SessionActivity($0).label })
        XCTAssertEqual(all.count, 7, "the gateway emits seven in-band names")
        XCTAssertEqual(labels.count, 7, "two frames render identically")
    }
}
