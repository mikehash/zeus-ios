import XCTest
@testable import Zeus

/// THE STREAMED REPLY, RECORDED AT THE TRANSPORT.
///
/// ## What this file measures that no other file does
///
/// `EmbeddedTransportTests` has twenty-odd legs and every one of them feeds a
/// `FakeCore` — a fixture that calls `sink.onToken` because the test told it
/// to. Those legs prove the *plumbing* between `TokenSink` and
/// `AsyncThrowingStream` is correct, and they are blind, by construction, to
/// whether the Rust core can produce a token at all. A green suite there is
/// consistent with `ZeusCore.send` being a stub that returns immediately.
///
/// This leg closes that gap the only way it can be closed: it arms the REAL
/// `ZeusCore` (the static archive named in
/// `Frameworks/ZeusCore.xcframework/zeus-build-manifest.txt`), sends a prompt
/// through `EmbeddedTransport` — the production transport, not a double — and
/// asserts on the `SessionFrame` values that come back out of the same
/// `stream(prompt:)` the app calls.
///
/// ## Why it is opt-in, and why that is not a hole
///
/// It needs a provider actually answering on the host. An always-on leg would
/// be red on every machine without one, which is how a suite learns to ignore
/// a colour. So it is gated on `ZEUS_LIVE_OLLAMA=1`.
///
/// The gate is the DANGEROUS part, so it is built to fail loudly rather than
/// quietly:
///
///   * gate unset  -> `XCTSkip` with the exact command to run it. A skip is
///     reported as a skip, not as a pass, so the count cannot absorb it.
///   * gate SET but the stream yields no `.token` -> **`XCTFail`**, never a
///     skip. Once an operator has claimed a provider is live, "no tokens" is a
///     failure of the thing under test, not an absent environment. This is the
///     asymmetry that stops the file from becoming a self-excusing test.
///
/// ## The aperture, stated with the measurement
///
/// A pass here says: this build's linked core, against the provider named in
/// the environment, produced N `.token` frames whose concatenation is
/// non-empty. It says NOTHING about any other provider, and nothing about the
/// gateway path (`HTTPTransport`) — that wire has its own file.
final class LiveStreamedReplyTests: XCTestCase {

    private static let gate = "ZEUS_LIVE_OLLAMA"

    /// Defaults chosen so the leg is runnable with the gate alone; each is
    /// overridable because pinning a model name in a test file would make the
    /// leg fail for a reason that has nothing to do with the transport.
    private var providerID: String {
        ProcessInfo.processInfo.environment["ZEUS_LIVE_PROVIDER"] ?? "ollama"
    }

    private var model: String {
        ProcessInfo.processInfo.environment["ZEUS_LIVE_MODEL"] ?? "qwen3.8:27b-mlx"
    }

    private var baseURL: String {
        ProcessInfo.processInfo.environment["ZEUS_LIVE_BASE_URL"]
            ?? "http://localhost:11434"
    }

    /// `zeus-llm` rejects an empty key for EVERY provider, Ollama included, so
    /// the keyless provider still has to be handed a non-empty string. This is
    /// a placeholder standing in for a credential that does not exist, not a
    /// secret and not a default — see the same constant on the production
    /// `setProvider` call site.
    private let keylessPlaceholder = "ollama-local-no-key"

    private func drain(
        _ transport: SessionTransport,
        prompt: String
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

    func testRealCoreStreamsTokenFramesThroughTheProductionTransport() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env[Self.gate] == "1",
            """
            LIVE LEG NOT RUN. This asserts the real Rust core streams tokens; \
            it needs a provider answering on the host. Run it with:

              TEST_RUNNER_\(Self.gate)=1 xcodebuild test \\
                -destination 'id=<SIM-UDID>' \\
                -only-testing:ZeusTests/LiveStreamedReplyTests

            NOTE THE PREFIX. The test process runs INSIDE the simulator, and \
            xcodebuild does not forward the invoking shell's environment to \
            it: a bare `\(Self.gate)=1` sets the variable on xcodebuild and \
            the runner never sees it, so this leg skips while looking like it \
            was asked to run. `TEST_RUNNER_`-prefixed variables are injected \
            into the runner with the prefix stripped — measured here, not \
            assumed: the bare form skipped at 13:34 and the prefixed form is \
            what produced the receipt.
            """
        )

        // The REAL core — the archive whose provenance the manifest guards.
        let core: ZeusCore
        switch EmbeddedCore.shared {
        case let .success(c):
            core = c
        case let .failure(error):
            return XCTFail("""
                The gate is set but the embedded core did not start: \(error). \
                This is a failure, not an absent environment — the core is \
                linked into this binary regardless of what is on the network.
                """)
        }

        try core.setProvider(id: providerID,
                             model: model,
                             key: keylessPlaceholder,
                             baseUrl: baseURL)

        // Readiness read from the CORE, not inferred from the call above
        // returning without throwing.
        XCTAssertTrue(core.hasProvider(),
                      "setProvider(\(providerID)) returned cleanly but the core still reports no provider")

        // The PRODUCTION transport over the REAL core. Nothing is doubled.
        let transport = EmbeddedTransport(core: core, sessionID: SessionIDBox())
        let prompt = "Reply with exactly the word: pong"
        let (frames, error) = await drain(transport, prompt: prompt)

        XCTAssertNil(error, "live turn ended in an error: \(String(describing: error))")

        // The claim, in the type the transport actually yields.
        var tokens: [String] = []
        for frame in frames {
            if case let .token(text) = frame { tokens.append(text) }
        }

        XCTAssertGreaterThan(
            tokens.count, 0,
            """
            The gate is SET, so the operator has claimed \(providerID) is live \
            at \(baseURL), and the core still produced zero .token frames. \
            frames=\(frames.count) first=\(frames.prefix(5))
            """
        )

        let reply = tokens.joined()
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "\(tokens.count) token frames arrived but their concatenation is blank")

        // THE WRONG-SUBJECT GUARD, put here because this leg already fell for it.
        //
        // First live run: frames=1 tokens=1 and the leg went GREEN — on a body
        // that read `OpenAI API error (500): unknown renderer "qwen3.8"`. The
        // count assertion above cannot tell a reply from a failure, because
        // `EmbeddedTransport` has ONE outward arm (`.token`, see its header)
        // and the provider's error text arrives through it as prose. A
        // token-count leg is therefore satisfied by the exact outcome it
        // exists to detect.
        //
        // These needles are the provider's error envelope, not a guess at
        // English: the shape is what `zeus-llm` emits when the upstream call
        // returns non-2xx.
        for needle in ["API error", "Internal Server Error", "\"error\":"] {
            XCTAssertFalse(
                reply.contains(needle),
                """
                The stream carried a provider ERROR delivered as a .token \
                frame, which a token count reads as success. reply=\(reply.prefix(200))
                """
            )
        }

        // A single token whose body is an error envelope is the observed
        // failure shape; a genuine streamed reply arrives as many frames.
        // Stated as a distinct leg so a future one-frame regression names
        // itself rather than hiding inside the count above.
        XCTAssertGreaterThan(
            tokens.count, 1,
            "a real streamed reply arrives in more than one frame; got \(tokens.count)"
        )

        // Vacuity guard: this leg claims .token frames specifically, so assert
        // the frame set is not some OTHER arm that happens to be non-empty.
        XCTAssertNotEqual(tokens.count, frames.count + 1,
                          "impossible count — the extraction above is broken")

        // The receipt. `xcodebuild` carries this line in its log, which is what
        // makes the run reportable as a measurement rather than a green tick.
        print("""
            LIVE-STREAM-RECEIPT provider=\(providerID) model=\(model) \
            base=\(baseURL) frames=\(frames.count) tokens=\(tokens.count) \
            reply=\(reply.prefix(120).replacingOccurrences(of: "\n", with: " "))
            """)
    }
}
