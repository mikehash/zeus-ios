import XCTest
@testable import Zeus

/// SSE decoder legs.
///
/// ## The aperture, stated first because it is the point
///
/// Every leg in the sibling files constructs a `SessionFrame` in Swift. **Not
/// one of them has ever seen a payload byte.** That is the same shape as a test
/// router supplying the request extension production omits: a suite that can
/// only pass, because the fixture and the subject were written by the same hand
/// from the same assumption.
///
/// These legs are built from BYTES. Where a byte string below is marked
/// OBSERVED it was captured off a live socket; where it is marked SOURCE it was
/// constructed from a read of the producer at `2dc487bde` and is honestly a
/// weaker artifact. The distinction is kept per-fixture rather than averaged,
/// because rounding it up is how "we tested the wire" gets said about a suite
/// that tested its own imagination.
///
/// **No device-chat frame has been observed by anyone.** `/v1/devices/:id/chat`
/// returns 500 on this box (binary predates the fix by ~2 days; landed ≠ live).
/// The framing bytes below are OBSERVED on the sibling route
/// `/v1/chat/completions`; the seven names and their field keys are SOURCE.
final class SSEDecoderTests: XCTestCase {

    // MARK: - Stage 1: framing (bytes OBSERVED on /v1/chat/completions)

    /// OBSERVED: 418 bytes, `HTTP 200`, `content-type: text/event-stream`,
    /// **CR bytes = 0** — this server separates with bare LF, not CRLF. And
    /// `^data: ` × 3 with `^data:[^ ]` × 0, so the optional space is present
    /// here. Both facts are properties of THIS gateway, not of SSE.
    func testObservedGatewayFramingYieldsOneEventPerBlock() {
        var reader = SSEFrameReader()
        let observed = """
        data: {"event":"token","text":"He"}

        data: {"event":"token","text":"llo"}

        data: {"event":"done","text":"Hello"}


        """
        let events = reader.feed(observed)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].data, #"{"event":"token","text":"He"}"#)
        XCTAssertEqual(events[2].data, #"{"event":"done","text":"Hello"}"#)
    }

    /// The keepalive. axum's `KeepAlive::default()` emits `b":\n\n"` every 15s
    /// — byte-identical in 0.6.20 (`sse.rs:196`) and 0.7.9 (`sse.rs:188`), the
    /// two majors `zeus-api` links simultaneously. The device route's turn
    /// budget is 1800s (`chat_handlers.rs:508`), so on a 30-minute cook this
    /// frame is the COMMON case.
    ///
    /// It must produce an event with NO data — not `nil`, not an error. A
    /// decoder that reports "bad JSON" here sends the operator to look at the
    /// agent for a fact about the transport.
    func testKeepAliveCommentIsAnEventWithNoData() {
        var reader = SSEFrameReader()
        let events = reader.feed(":\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].data)
        XCTAssertTrue(events[0].isComment)

        guard case .success(.ignored(reason: .noData)) = SessionFrameDecoder.decode(events[0]) else {
            return XCTFail("keepalive must be IGNORED with a reason, not decoded or failed")
        }
    }

    /// A keepalive interleaved with real frames must not disturb them. This is
    /// the leg that would have caught the decoder I was about to ship: it
    /// JSON-parsed every frame, so a healthy 30-minute stream threw on its
    /// first quiet interval.
    func testKeepAliveBetweenFramesLeavesThePayloadsIntact() {
        var reader = SSEFrameReader()
        let events = reader.feed("""
        data: {"event":"token","text":"a"}

        :

        data: {"event":"token","text":"b"}


        """)
        XCTAssertEqual(events.count, 3)
        XCTAssertNil(events[1].data)
        XCTAssertEqual(events[0].data, #"{"event":"token","text":"a"}"#)
        XCTAssertEqual(events[2].data, #"{"event":"token","text":"b"}"#)
    }

    /// The optional space. Per spec ONE leading space is framing; this gateway
    /// sends it and a conformant one need not. A fixed six-byte strip works on
    /// the former and mangles the latter — the Rust twin ships the strict form
    /// at 14 sites and the literal `&line[6..]` at `zeus-llm/src/lib.rs:2831`.
    func testBothDataSpellingsDecodeIdentically() {
        XCTAssertEqual(SSEFrameReader.parseBlock(#"data: {"event":"token","text":"x"}"#)?.data,
                       SSEFrameReader.parseBlock(#"data:{"event":"token","text":"x"}"#)?.data)
    }

    /// Only the FIRST space is framing. A payload beginning with whitespace
    /// keeps the rest — `trimmingCharacters` here would silently eat data.
    func testOnlyOneLeadingSpaceIsStripped() {
        XCTAssertEqual(SSEFrameReader.parseBlock("data:   x")?.data, "  x")
    }

    /// CRLF. Measured 0 CR bytes on this server, so this leg is about the
    /// server we do NOT have. Untrimmed, `\r` survives into the payload; JSON
    /// tolerates it as whitespace, so tokens keep flowing and only the
    /// TERMINATOR silently stops matching — the failure that looks like a hang.
    func testCRLFFramingDecodesIdenticallyToLF() {
        // The fixture is FULLY CRLF: `\r\n` after the field line AND `\r\n` for
        // the blank line, i.e. the terminator is `\r\n\r\n`. The first draft of
        // this leg ended `\r\n\n` — a half-CRLF stream no server emits — and it
        // was satisfied by the LF terminator alone, so the CRLF branch it
        // exists to guard SURVIVED deletion. A fixture one byte short of the
        // real thing is a fixture that tests the arm you already had.
        var crlf = SSEFrameReader()
        var lf = SSEFrameReader()
        let a = crlf.feed("data: {\"event\":\"token\",\"text\":\"x\"}\r\n\r\n")
        let b = lf.feed("data: {\"event\":\"token\",\"text\":\"x\"}\n\n")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.first?.data, #"{"event":"token","text":"x"}"#)
    }

    /// Two events in one buffer with DIFFERENT line endings. Pins that the
    /// terminator search takes the EARLIEST match rather than the first
    /// spelling it looks for — searching `\r\n\r\n` first would swallow the LF
    /// event whole and emit one merged frame.
    func testMixedLineEndingsCutAtTheEarliestTerminator() {
        var reader = SSEFrameReader()
        let events = reader.feed("data: a\n\ndata: b\r\n\r\n")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].data, "a")
        XCTAssertEqual(events[1].data, "b")
    }

    /// ③ The rejoin. `Event::data()` splits on `\n` into N `data:` lines. Today
    /// `json!().to_string()` is compact so N == 1 and a one-line-per-event
    /// reader is right BY COINCIDENCE. The Rust twin has 0 of 14 sites that
    /// rejoin: it parses the first line and `continue`s past the rest, so a
    /// pretty-printed payload does not lose its tail — it loses everything but
    /// the first fragment.
    func testMultipleDataLinesRejoinWithNewline() {
        let block = "data: {\ndata:   \"event\": \"token\",\ndata:   \"text\": \"x\"\ndata: }"
        let event = SSEFrameReader.parseBlock(block)
        XCTAssertEqual(event?.data, "{\n  \"event\": \"token\",\n  \"text\": \"x\"\n}")

        // …and the rejoined payload is decodable, which is the whole point.
        guard case .success(.frame(.token("x"))) = SessionFrameDecoder.decode(event!) else {
            return XCTFail("a fragmented frame must decode to the same frame as a compact one")
        }
    }

    /// Chunk boundaries are TCP-shaped, not SSE-shaped. An event split across
    /// two `URLSession.bytes` chunks must not be lost or half-parsed.
    func testEventSplitAcrossChunksIsReassembled() {
        var reader = SSEFrameReader()
        XCTAssertTrue(reader.feed("data: {\"event\":\"tok").isEmpty)
        let events = reader.feed("en\",\"text\":\"x\"}\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, #"{"event":"token","text":"x"}"#)
    }

    /// A server closing after the last frame without a trailing blank line is
    /// legal. Without `finish()` the final frame — which on this route is
    /// `done`, carrying the entire reply — is silently dropped.
    func testFinishFlushesATrailingUnterminatedEvent() {
        var reader = SSEFrameReader()
        XCTAssertTrue(reader.feed(#"data: {"event":"done","text":"bye"}"#).isEmpty)
        let events = reader.finish()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, #"{"event":"done","text":"bye"}"#)
    }

    /// `finish()` on an empty buffer yields nothing — the vacuity floor. Without
    /// this, a reader that fabricated an empty event on close would pass every
    /// leg above.
    func testFinishOnEmptyBufferYieldsNothing() {
        var reader = SSEFrameReader()
        XCTAssertTrue(reader.finish().isEmpty)
    }

    // MARK: - Stage 3: the seven names (field keys SOURCE-read at 2dc487bde)

    private func decode(_ payload: String) -> Result<SSEDecodeOutcome, SSEDecodeError> {
        SessionFrameDecoder.decode(SSEEvent(data: payload, name: nil))
    }

    /// All seven, each with the field keys the producer actually emits.
    ///
    /// Note `tool` — NOT `name`. `chat_handlers.rs:529`/`:533` spell the JSON
    /// key `tool` while the Rust field is `name`. A Swift-constructed fixture
    /// cannot notice that disagreement, because it never spells the key at all.
    func testSevenNamesDecodeFromTheirWirePayloads() {
        guard case .success(.frame(.token("hi"))) =
                decode(#"{"event":"token","text":"hi"}"#) else { return XCTFail("token") }

        guard case .success(.frame(.thinking("hm"))) =
                decode(#"{"event":"thinking","text":"hm"}"#) else { return XCTFail("thinking") }

        guard case .success(.frame(.toolStart(name: "grep"))) =
                decode(#"{"event":"tool_start","tool":"grep","input":"x"}"#) else { return XCTFail("tool_start") }

        guard case .success(.frame(.toolEnd(name: "grep", output: "3 hits"))) =
                decode(#"{"event":"tool_end","tool":"grep","output":"3 hits"}"#) else { return XCTFail("tool_end") }

        guard case .success(.frame(.iteration(4))) =
                decode(#"{"event":"iter","n":4}"#) else { return XCTFail("iter") }

        guard case .success(.frame(.done("Hello"))) =
                decode(#"{"event":"done","text":"Hello"}"#) else { return XCTFail("done") }

        guard case .success(.frame(.failure("boom"))) =
                decode(#"{"event":"error","error":"boom"}"#) else { return XCTFail("error") }
    }

    /// `iter` and `error` are the two names the handler's OWN doc comment at
    /// `:425-426` omits — it lists five. A decoder built from that prose drops a
    /// progress frame and renders a real agent failure as an unknown frame.
    /// This leg exists so the omission cannot come back through a rewrite: it
    /// asserts specifically that these two are NOT `.unknownEvent`.
    func testTheTwoNamesTheDocCommentOmitsAreNotUnknown() {
        for payload in [#"{"event":"iter","n":1}"#, #"{"event":"error","error":"e"}"#] {
            if case .failure(.unknownEvent) = decode(payload) {
                XCTFail("\(payload) decoded as unknown — the five-name decoder is back")
            }
        }
    }

    /// `done` CARRIES THE REPLY. Pinned as a payload leg because the arm took
    /// no associated value until `a1fb4c3a`, and a decoder that drops `text`
    /// leaves the transcript EMPTY on a successful no-token turn —
    /// `inbox.rs:1098` asserts exactly such a turn, panicking on every non-`Done`
    /// arm.
    func testDoneCarriesTheReplyRatherThanTerminatingEmpty() {
        guard case .success(.frame(.done(let text))) =
                decode(#"{"event":"done","text":"the whole reply"}"#) else { return XCTFail() }
        XCTAssertEqual(text, "the whole reply")
    }

    /// The `error` payload has NO `text` key at all
    /// (`chat_handlers.rs:541-543`), which is why the engine keeps accumulated
    /// tokens on this frame instead of replacing. Asserting the ABSENCE is the
    /// vacuity floor under that rule.
    func testErrorFrameCarriesNoTextKey() {
        let object = try! JSONSerialization.jsonObject(
            with: Data(#"{"event":"error","error":"boom"}"#.utf8)) as! [String: Any]
        XCTAssertNil(object["text"])
    }

    // MARK: - Stage 2/3: failures are three different facts

    /// A comment frame, a malformed payload and an unrecognised name are three
    /// DIFFERENT failures. A single-stage decoder reports all three as "bad
    /// JSON" — the layering is the whole value of the cut.
    func testTheThreeFailureModesAreDistinguishable() {
        // ① no data → ignored, not an error
        guard case .success(.ignored(reason: .noData)) =
                SessionFrameDecoder.decode(SSEEvent(data: nil, name: nil)) else { return XCTFail("①") }
        // ② data that is not JSON → notJSON
        guard case .failure(.notJSON) = decode("<html>502</html>") else { return XCTFail("②") }
        // ③ valid JSON, unrecognised name → unknownEvent CARRYING the name
        guard case .failure(.unknownEvent(name: "quantum")) =
                decode(#"{"event":"quantum"}"#) else { return XCTFail("③") }
    }

    /// JSON that is not an OBJECT (an array, a bare string) is `notJSON` rather
    /// than a crash — `as? [String: Any]` is the guard and this pins it.
    func testNonObjectJSONIsNotJSONRatherThanACrash() {
        guard case .failure(.notJSON) = decode("[1,2,3]") else { return XCTFail("array") }
        guard case .failure(.notJSON) = decode("\"just a string\"") else { return XCTFail("string") }
    }

    /// A JSON object with no `event` key is structurally foreign — distinct
    /// from an object whose name we do not know.
    func testObjectWithoutEventKeyIsItsOwnFailure() {
        guard case .failure(.noEventField) = decode(#"{"text":"orphan"}"#) else { return XCTFail() }
    }

    /// A known name missing a field it needs names BOTH the event and the
    /// field. This is the arm that would have caught `tool_end`'s fabricated
    /// `ok:` had any leg ever seen a payload.
    func testKnownNameWithMissingFieldNamesTheEventAndTheField() {
        guard case .failure(.missingField(event: "token", field: "text")) =
                decode(#"{"event":"token"}"#) else { return XCTFail("token") }
        guard case .failure(.missingField(event: "tool_end", field: "output")) =
                decode(#"{"event":"tool_end","tool":"grep"}"#) else { return XCTFail("tool_end") }
        guard case .failure(.missingField(event: "iter", field: "n")) =
                decode(#"{"event":"iter"}"#) else { return XCTFail("iter") }
    }

    /// `tool_end` has no `ok` on the wire. Asserting the absence, not just that
    /// the decoder ignores it: a fixture that supplied `ok` would keep passing a
    /// decoder that required it, which is exactly how the fabricated field
    /// survived 56 green legs.
    func testToolEndPayloadHasNoOkField() {
        let object = try! JSONSerialization.jsonObject(
            with: Data(#"{"event":"tool_end","tool":"grep","output":"x"}"#.utf8)) as! [String: Any]
        XCTAssertNil(object["ok"])
        XCTAssertNil(object["success"])
    }

    // MARK: - [DONE]: tolerated, non-terminating, never required

    /// `[DONE]` hits in the device_chat block = 0; in the OpenAI-compat block =
    /// 2 (`:1162`, `:1283`). Our own Rust client REQUIRES it at
    /// `zeus-llm/src/lib.rs:2833`, `:3898`, `codex.rs:261`. So the sentinel is
    /// mandatory on the routes that send it and never arrives on this one.
    ///
    /// Written as an EXPLICIT ignore so the next reader sees the route split
    /// was DECIDED rather than unnoticed — an omission and a decision look
    /// identical in code and are opposite in meaning.
    func testDoneSentinelIsExplicitlyIgnoredRatherThanParsedOrFatal() {
        guard case .success(.ignored(reason: .doneSentinel)) = decode("[DONE]") else {
            return XCTFail("[DONE] must be a NAMED ignore, not notJSON and not a terminator")
        }
    }

    /// …and it is NOT the terminator here. The stream ends on the in-band
    /// `done`/`error`. A client that treats `[DONE]` as required hangs on this
    /// route; this leg pins that the ignore is inert rather than load-bearing.
    func testStreamTerminatesOnInBandDoneNotOnTheSentinel() {
        var reader = SSEFrameReader()
        let events = reader.feed("data: {\"event\":\"done\",\"text\":\"end\"}\n\n")
        guard case .success(.frame(.done("end"))) =
                SessionFrameDecoder.decode(events[0]) else { return XCTFail() }
    }

    // MARK: - End to end, from observed framing through to frames

    /// The full ladder on one byte string: keepalive, fragmented frame, both
    /// `data:` spellings, CRLF, a split chunk, and the seven names underneath.
    func testFullStreamFromBytesToFrames() {
        var reader = SSEFrameReader()
        var frames: [SessionFrame] = []
        var ignored = 0

        let wire = [
            ":\n\n",
            "data: {\"event\":\"iter\",\"n\":1}\n\n",
            "data:{\"event\":\"tool_start\",\"tool\":\"grep\",\"input\":\"x\"}\n\n",
            "data: {\"event\":\"tool_end\",\"tool\":\"grep\",\"output\":\"3\"}\r\n\n",
            ":\n\n",
            "data: {\"event\":\"token\",\"text\":\"He\"}\n\ndata: {\"event\":\"tok",
            "en\",\"text\":\"llo\"}\n\n",
            "data: [DONE]\n\n",
            "data: {\"event\":\"done\",\"text\":\"Hello\"}",
        ]
        for chunk in wire {
            for event in reader.feed(chunk) {
                switch SessionFrameDecoder.decode(event) {
                case .success(.frame(let f)): frames.append(f)
                case .success(.ignored):      ignored += 1
                case .failure(let e):         XCTFail("decode failed: \(e)")
                }
            }
        }
        for event in reader.finish() {
            if case .success(.frame(let f)) = SessionFrameDecoder.decode(event) { frames.append(f) }
        }

        XCTAssertEqual(ignored, 3, "two keepalives and one [DONE]")
        XCTAssertEqual(frames, [
            .iteration(1),
            .toolStart(name: "grep"),
            .toolEnd(name: "grep", output: "3"),
            .token("He"),
            .token("llo"),
            .done("Hello"),
        ])
    }
}
