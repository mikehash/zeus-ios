import XCTest
@testable import Zeus

// MARK: - RIDER ② — the off-main claim, asserted at COMPILE TIME
//
// `EmbeddedTransport` must never be called on the main actor, because
// `ZeusCore.send` is `rt.block_on` and blocks its caller for the whole turn
// (rust/zeus-core-bridge/src/lib.rs:186). A runtime assertion could only
// observe the thread a test happened to run on; the obligation is about every
// call site, including ones nobody wrote yet.
//
// THIS FILE HAS NO `@MainActor` ANNOTATION, and the two facts below are checked
// by the compiler rather than by an XCTest expectation:
//
//   1. `EmbeddedTransport` is nonisolated — `makeNonisolated()` constructs one
//      from a nonisolated context. Annotating the type `@MainActor` breaks this
//      line at compile time.
//   2. `EmbeddedTransport` is `Sendable` — `requireSendable` accepts only a
//      `Sendable` value, so removing the conformance (which `SessionTransport`
//      requires) fails to build.
//
// A compile-time fact cannot be reported as a passing test, so it is stated
// here and exercised by the file's existence. `testTheCompileTimeFactsHold`
// below runs the two functions so a reader grepping for coverage finds a
// symbol rather than only a comment.

private func requireSendable<T: Sendable>(_ value: T) -> T { value }

private func makeNonisolated(core: ZeusCoreProtocol) -> EmbeddedTransport {
    EmbeddedTransport(core: core, sessionID: SessionIDBox())
}

// MARK: - Fake core

/// A `ZeusCoreProtocol` that drives the sink on a schedule the test controls.
///
/// This fakes the CORE, not the transport. Rider: the ruling's leg is a real
/// streamed reply through the bridge in the simulator — that lives in
/// `testRealBridgeStreamsThroughTheTransport` below and needs a provider key.
/// These legs cover the adapter's edges (double-finish, error-after-token,
/// sync throw) which a real provider cannot be asked to produce on demand.
private final class FakeCore: ZeusCoreProtocol, @unchecked Sendable {
    enum Script {
        case tokensThenComplete([String])
        case tokensThenError([String], String)
        case completeThenMoreTokens([String])
        case throwsSynchronously(BridgeError)
    }

    let script: Script
    private(set) var sentSessionIDs: [String] = []
    private(set) var sentTexts: [String] = []
    private let lock = NSLock()

    init(_ script: Script) { self.script = script }

    func send(sessionId: String, text: String, sink: TokenSink) throws {
        lock.lock()
        sentSessionIDs.append(sessionId)
        sentTexts.append(text)
        lock.unlock()

        switch script {
        case let .tokensThenComplete(tokens):
            tokens.forEach { sink.onToken(token: $0) }
            sink.onComplete(fullText: tokens.joined())
        case let .tokensThenError(tokens, message):
            tokens.forEach { sink.onToken(token: $0) }
            sink.onError(message: message)
        case let .completeThenMoreTokens(tokens):
            tokens.forEach { sink.onToken(token: $0) }
            sink.onComplete(fullText: tokens.joined())
            // Everything past here must be DROPPED — see finishExactlyOnce.
            sink.onToken(token: "AFTER")
            sink.onError(message: "AFTER")
        case let .throwsSynchronously(error):
            throw error
        }
    }

    func indexSize() -> UInt32 { 0 }
    func remember(fact: String) throws {}
    func search(query: String) -> [SearchHit] { [] }
    func sessions() throws -> [SessionInfo] { [] }
    func setProvider(id: String, model: String, key: String) throws {}
}

final class EmbeddedTransportTests: XCTestCase {

    // MARK: - Helpers

    private func drain(
        _ transport: SessionTransport,
        prompt: String = "p"
    ) async -> (frames: [SessionFrame], error: Error?) {
        var frames: [SessionFrame] = []
        do {
            for try await frame in transport.stream(prompt: prompt) {
                frames.append(frame)
            }
            return (frames, nil)
        } catch {
            return (frames, error)
        }
    }

    // MARK: - Rider ② (compile-time)

    func testTheCompileTimeFactsHold() {
        let core = FakeCore(.tokensThenComplete([]))
        // Constructed from a NONISOLATED context — see the file header.
        let transport = makeNonisolated(core: core)
        // Accepted by a `Sendable`-constrained generic.
        _ = requireSendable(transport)
        // Vacuity guard: the two statements above are the assertion. If this
        // ever becomes the only line in the test, the test is measuring
        // nothing.
        XCTAssertTrue(transport is SessionTransport)
    }

    // MARK: - Push → pull

    func testTokensArriveInOrderAsTokenFrames() async {
        let core = FakeCore(.tokensThenComplete(["Hel", "lo", " world"]))
        let transport = EmbeddedTransport(core: core, sessionID: SessionIDBox())

        let (frames, error) = await drain(transport)

        XCTAssertNil(error)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.compactMap(\.transcriptText).joined(), "Hello world")
    }

    /// RIDER ③ — the narrower wire, asserted rather than described.
    ///
    /// v1 emits `.token` ONLY. This test fails the day a thinking or tool frame
    /// starts arriving from the embedded path, which is the day the doc on
    /// `EmbeddedTransport` stops being true — so the claim and its check move
    /// together instead of drifting.
    func testEmbeddedWireEmitsTokenFramesAndNothingElse() async {
        let core = FakeCore(.tokensThenComplete(["a", "b"]))
        let transport = EmbeddedTransport(core: core, sessionID: SessionIDBox())

        let (frames, _) = await drain(transport)

        XCTAssertFalse(frames.isEmpty, "vacuity: no frames means the check below is empty")
        for frame in frames {
            guard case .token = frame else {
                return XCTFail("embedded wire emitted a non-token frame: \(frame)")
            }
        }
    }

    /// `onComplete(fullText:)` is DISCARDED. Yielding it would double the reply.
    ///
    /// The mutation this kills: yielding `.token(fullText)` in `onComplete`
    /// leaves every existing order/content assertion green (the tokens are all
    /// still there, in order) and doubles the transcript. Only a count-and-join
    /// against the exact expected string sees it.
    func testCompletionTextIsNotYieldedAgain() async {
        let core = FakeCore(.tokensThenComplete(["one", "two"]))
        let transport = EmbeddedTransport(core: core, sessionID: SessionIDBox())

        let (frames, _) = await drain(transport)

        XCTAssertEqual(frames.count, 2, "completion text was re-yielded: \(frames)")
        XCTAssertEqual(frames.compactMap(\.transcriptText).joined(), "onetwo")
    }

    func testErrorAfterTokensKeepsThePartialAndThrows() async {
        let core = FakeCore(.tokensThenError(["par", "tial"], "model exploded"))
        let transport = EmbeddedTransport(core: core, sessionID: SessionIDBox())

        let (frames, error) = await drain(transport)

        // The partial is KEPT — same rule as `SessionTransport`'s doc: a
        // half-arrived answer is data, and discarding it is a second failure.
        XCTAssertEqual(frames.compactMap(\.transcriptText).joined(), "partial")
        XCTAssertEqual(error as? TransportError,
                       .embedded(detail: "model exploded"))
    }

    /// The three paths into `finish` are collapsed to one.
    func testFinishHappensExactlyOnce() async {
        let core = FakeCore(.completeThenMoreTokens(["x"]))
        let transport = EmbeddedTransport(core: core, sessionID: SessionIDBox())

        let (frames, error) = await drain(transport)

        XCTAssertNil(error, "a post-finish onError leaked into the stream")
        XCTAssertEqual(frames.compactMap(\.transcriptText).joined(), "x",
                       "a post-finish token leaked into the transcript")
    }

    /// A synchronous `BridgeError` from `send` still terminates the stream.
    ///
    /// Without the `catch` in `stream`, this test HANGS rather than fails —
    /// the consumer awaits a continuation nobody finished. That is why it
    /// exists: the failure mode is a freeze, not a red assertion.
    func testSynchronousBridgeErrorTerminatesTheStream() async {
        let core = FakeCore(.throwsSynchronously(.Core("workspace is read-only")))
        let transport = EmbeddedTransport(core: core, sessionID: SessionIDBox())

        let (frames, error) = await drain(transport)

        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(error as? TransportError,
                       .embedded(detail: "workspace is read-only"))
    }

    /// `BridgeError.NoProvider` speaks the SAME sentence as the disarmed
    /// composer. Two spellings of one state is how an operator comes to
    /// believe there are two states.
    func testNoProviderBackstopSaysTheSameWordsAsTheDisarm() async {
        let core = FakeCore(.throwsSynchronously(.NoProvider))
        let transport = EmbeddedTransport(core: core, sessionID: SessionIDBox())

        let (_, error) = await drain(transport)

        XCTAssertEqual(error as? TransportError,
                       .embedded(detail: GatewayConfig.noProviderMessage))
        XCTAssertEqual(GatewayConfig.local(.noProvider).disarmReason,
                       GatewayConfig.noProviderMessage)
    }

    // MARK: - Session identity

    /// Turn two must reuse turn one's id, or every message is a new session in
    /// the core and the conversation has no memory of itself.
    ///
    /// Invisible in a one-turn test — which is the entire reason this one
    /// sends twice.
    func testTheSecondTurnReusesTheFirstTurnsSessionID() async {
        let core = FakeCore(.tokensThenComplete(["a"]))
        let box = SessionIDBox()
        let transport = EmbeddedTransport(core: core, sessionID: box)

        _ = await drain(transport, prompt: "one")
        _ = await drain(transport, prompt: "two")

        XCTAssertEqual(core.sentSessionIDs.count, 2)
        XCTAssertEqual(core.sentSessionIDs[0], core.sentSessionIDs[1])
        XCTAssertFalse(core.sentSessionIDs[0].isEmpty)
        // POS control: the two turns really were distinct calls, so the
        // equality above is about the id and not about a single send.
        XCTAssertEqual(core.sentTexts, ["one", "two"])
    }

    func testAPreexistingSessionIDIsHonoured() async {
        let core = FakeCore(.tokensThenComplete(["a"]))
        let transport = EmbeddedTransport(core: core,
                                          sessionID: SessionIDBox("sess-42"))

        _ = await drain(transport)

        XCTAssertEqual(core.sentSessionIDs, ["sess-42"])
    }

    // MARK: - The four-arm switch

    /// `.local` returns the embedded wire — and the other three arms are
    /// asserted in the same test so a mutation that returns `EmbeddedTransport`
    /// for everything cannot pass.
    func testMakeTransportRoutesAllFourArms() {
        let box = SessionIDBox()

        XCTAssertTrue(makeTransport(for: .absent, sessionID: box, credentials: StubCredentialProvider())
                      is UnconfiguredTransport)
        XCTAssertTrue(makeTransport(for: .malformed(raw: "x", reason: .notAURL),
                                    sessionID: box, credentials: StubCredentialProvider()) is MisconfiguredTransport)
        XCTAssertTrue(makeTransport(
            for: .resolved(.init(url: URL(string: "http://a.b")!, token: nil)),
            sessionID: box,
            credentials: StubCredentialProvider()) is HTTPTransport)

        // Both readiness values return the SAME transport: `.noProvider` is
        // rendered by the surface before a send, not by handing back a
        // crippled wire.
        for readiness: GatewayConfig.LocalReadiness in [.ready, .noProvider] {
            let transport = makeTransport(for: .local(readiness), sessionID: box, credentials: StubCredentialProvider())
            // `EmbeddedCore.shared` may legitimately fail in a test process
            // that cannot create its Application Support directory, and that
            // arm returns `MisconfiguredTransport` by design. Accept either,
            // and REFUSE the two that would mean the routing is wrong.
            XCTAssertFalse(transport is UnconfiguredTransport,
                           "\(readiness) routed to the arm that means nothing is listening")
            XCTAssertFalse(transport is HTTPTransport,
                           "\(readiness) routed to the network")
        }
    }

    // MARK: - Rider ① — the third state is RENDERED

    func testOnlyNoProviderDisarmsTheComposer() {
        XCTAssertEqual(GatewayConfig.local(.noProvider).disarmReason,
                       "NO PROVIDER — SET ONE IN ROUTES")
        XCTAssertNil(GatewayConfig.local(.ready).disarmReason)

        // The unwired arms deliberately DO NOT disarm: their transports fail
        // loudly on send, and that failure landing in the transcript is the
        // designed signal. Disarming them would hide a broken build behind a
        // greyed-out button.
        XCTAssertNil(GatewayConfig.absent.disarmReason)
        XCTAssertNil(GatewayConfig.malformed(raw: "x", reason: .notAURL).disarmReason)
        XCTAssertNil(GatewayConfig.resolved(
            .init(url: URL(string: "http://a.b")!, token: nil)).disarmReason)
    }

    /// The send predicate itself. See the aperture note on `canSend`: this
    /// guards the DECISION, not the two lines that call it.
    func testCanSendRefusesOnlyWhenDisarmedOrEmpty() {
        XCTAssertTrue(SessionView.canSend(trimmedInput: "hi", disarmReason: nil))
        XCTAssertFalse(SessionView.canSend(trimmedInput: "hi",
                                           disarmReason: GatewayConfig.noProviderMessage))
        // Both legs of the conjunction, so a mutation to either half is caught.
        XCTAssertFalse(SessionView.canSend(trimmedInput: "", disarmReason: nil))
        XCTAssertFalse(SessionView.canSend(trimmedInput: "",
                                           disarmReason: GatewayConfig.noProviderMessage))
    }

    /// The four summaries are DISTINCT — a receipt that says the same thing
    /// for two different configs is a receipt that cannot be used.
    func testLocalSummariesAreDistinctFromEveryOtherArm() {
        let summaries = [
            GatewayConfig.absent.summary,
            GatewayConfig.local(.ready).summary,
            GatewayConfig.local(.noProvider).summary,
            GatewayConfig.malformed(raw: "x", reason: .notAURL).summary,
            GatewayConfig.resolved(
                .init(url: URL(string: "http://a.b")!, token: nil)).summary,
        ]
        XCTAssertEqual(Set(summaries).count, summaries.count,
                       "two configs render the same receipt: \(summaries)")
    }

    // MARK: - LinkState

    /// `.embedded` is not `.linked` and not `.unconfigured`, on every surface.
    ///
    /// The mutation this kills: mapping `.local` onto `.linked` in the
    /// `LinkMonitor` initialiser. That requires inventing a host and a
    /// millisecond count — a fabricated round-trip on a status pill, which is
    /// the exact defect the `t-12min` literal was deleted for.
    func testEmbeddedLinkStateIsItsOwnRenderEverywhere() {
        let embedded = LinkState.embedded
        let linked = LinkState.linked(host: "h", ms: 1)
        let unconfigured = LinkState.unconfigured

        XCTAssertNotEqual(embedded.statusLine, linked.statusLine)
        XCTAssertNotEqual(embedded.statusLine, unconfigured.statusLine)
        XCTAssertNotEqual(embedded.badgeText, linked.badgeText)
        XCTAssertNotEqual(embedded.badgeText, unconfigured.badgeText)
        XCTAssertNotEqual(embedded.subtitle, unconfigured.subtitle)

        // Reachable BY CONSTRUCTION — it is in this address space. Returning
        // false would disable the console against a working gateway.
        XCTAssertTrue(embedded.isLinked)
        XCTAssertFalse(unconfigured.isLinked)

        // No round-trip is claimed. `MS` appears in the linked line and must
        // not appear here.
        XCTAssertFalse(embedded.statusLine.contains("MS"))
    }

    /// A local core does not stop existing while the app is backgrounded, and
    /// showing LINKING… for it would advertise a probe that never runs.
    @MainActor
    func testSuspendDoesNotDowngradeTheEmbeddedState() {
        let monitor = LinkMonitor(config: .local(.ready), interval: .seconds(60))
        XCTAssertEqual(monitor.state, .embedded)
        monitor.suspend()
        XCTAssertEqual(monitor.state, .embedded)

        // POS control: suspend really does downgrade a state that CAN go
        // stale, so the assertion above is about the exemption and not about
        // a `suspend` that does nothing.
        let remote = LinkMonitor(
            config: .resolved(.init(url: URL(string: "http://a.b")!, token: nil)),
            interval: .seconds(60))
        remote.suspend()
        XCTAssertEqual(remote.state, .probing)
    }
}
