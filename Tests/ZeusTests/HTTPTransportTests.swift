import XCTest
@testable import Zeus

/// HTTP transport legs — codec and URL construction.
///
/// These are **pure**: no sockets, no `URLSession`, no network. The request
/// body, the response decode, the URL join and the excerpt bound are all
/// synchronous functions taking their input as parameters, and that is the
/// reason they are testable at all. A codec reachable only through a live
/// request is a codec with no failure legs, because every error path needs a
/// server willing to produce it on demand.
///
/// What is NOT covered here, stated rather than implied: no leg drives
/// `URLSession`, so the `.unreachable` arm and the cancellation path are
/// **unexercised by this file**. They are reachable only through a real or
/// injected session and that is the next cut, not this one.
final class HTTPTransportTests: XCTestCase {

    private func endpoint(_ s: String, token: String? = nil) -> GatewayConfig.Endpoint {
        GatewayConfig.Endpoint(url: URL(string: s)!, token: token)
    }

    // MARK: - URL construction

    /// The route is `/v1/chat` (zeus-api routes.rs:166). A base with a trailing
    /// slash and one without must land on the same URL — the difference is
    /// invisible in a config string and produces a 404 that reads like a dead
    /// gateway rather than a typo.
    func testChatURLJoinsRouteRegardlessOfTrailingSlash() {
        let bare = HTTPTransport.chatURL(base: URL(string: "http://10.0.0.5:8080")!)
        let slash = HTTPTransport.chatURL(base: URL(string: "http://10.0.0.5:8080/")!)
        XCTAssertEqual(bare.absoluteString, "http://10.0.0.5:8080/v1/chat")
        XCTAssertEqual(slash.absoluteString, "http://10.0.0.5:8080/v1/chat")
    }

    /// A base carrying a path prefix keeps it — a gateway behind a reverse
    /// proxy at `/zeus` is a real deployment, and truncating the prefix would
    /// silently retarget the request at the proxy root.
    func testChatURLPreservesBasePathPrefix() {
        let url = HTTPTransport.chatURL(base: URL(string: "https://host/zeus")!)
        XCTAssertEqual(url.absoluteString, "https://host/zeus/v1/chat")
    }

    // MARK: - Request encoding

    /// `ChatRequest` requires `message`. `session_id` is omitted on the first
    /// turn rather than sent as null — the gateway branches on the key being
    /// *present* (`if let Some(id) = &req.session_id`), so a null would not be
    /// equivalent to an absent key.
    func testFirstTurnBodyCarriesMessageAndNoSessionID() throws {
        let data = try HTTPTransport.encodeBody(prompt: "hello", sessionID: nil)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["message"] as? String, "hello")
        XCTAssertNil(object["session_id"])
    }

    func testSubsequentTurnBodyCarriesSessionID() throws {
        let data = try HTTPTransport.encodeBody(prompt: "again", sessionID: "sess-9")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["session_id"] as? String, "sess-9")
    }

    /// An empty session id is treated as absent. It is the shape a stale
    /// decode produces, and sending `"session_id": ""` would make the gateway
    /// resume a session named empty-string rather than opening a new one.
    func testEmptySessionIDIsOmittedNotSentBlank() throws {
        let data = try HTTPTransport.encodeBody(prompt: "x", sessionID: "")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["session_id"])
    }

    /// `stream` is not sent at all. This route does not stream; sending
    /// `false` would imply the client negotiated a capability it never asked
    /// for, and sending `true` would ask for a shape this decoder cannot read.
    func testBodyDoesNotClaimStreaming() throws {
        let data = try HTTPTransport.encodeBody(prompt: "x", sessionID: nil)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["stream"])
    }

    // MARK: - Response decoding

    func testDecodesResponseAndSessionID() throws {
        let body = #"{"response":"pong","session_id":"s1"}"#.data(using: .utf8)!
        XCTAssertEqual(try HTTPTransport.decode(body),
                       HTTPTransport.Reply(response: "pong", sessionID: "s1"))
    }

    /// `session_id` absent is fine — the reply is still usable. Only
    /// `response` is load-bearing.
    func testDecodesReplyWithoutSessionID() throws {
        let body = #"{"response":"pong"}"#.data(using: .utf8)!
        XCTAssertEqual(try HTTPTransport.decode(body),
                       HTTPTransport.Reply(response: "pong", sessionID: nil))
    }

    /// An unknown field must not break the client. The gateway's ChatResponse
    /// carries `tool_calls`, which this client does not model, and a strict
    /// decoder would reject every real reply.
    func testUnknownFieldsAreIgnored() throws {
        let body = #"{"response":"ok","tool_calls":[{"name":"x"}],"extra":1}"#
            .data(using: .utf8)!
        XCTAssertEqual(try HTTPTransport.decode(body).response, "ok")
    }

    /// **The dangerous case.** A 200 with no `response` key is a *successful*
    /// request that produced no answer. Yielding "" would put an empty agent
    /// bubble in the transcript, which renders as a silent reply and is
    /// indistinguishable from a model that chose to say nothing.
    func testTwoHundredWithNoResponseFieldThrows() {
        let body = #"{"session_id":"s1"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try HTTPTransport.decode(body)) { error in
            guard case TransportError.malformedResponse = error else {
                return XCTFail("expected .malformedResponse, got \(error)")
            }
        }
    }

    /// An empty string reply is NOT an error — it is a reply. This leg exists
    /// to keep the guard above from being written as `text.isEmpty`, which
    /// would conflate "the field is missing" with "the field is empty".
    func testEmptyStringResponseIsAValidReply() throws {
        let body = #"{"response":""}"#.data(using: .utf8)!
        XCTAssertEqual(try HTTPTransport.decode(body).response, "")
    }

    func testNonJSONBodyThrowsMalformed() {
        let body = "<html>502 Bad Gateway</html>".data(using: .utf8)!
        XCTAssertThrowsError(try HTTPTransport.decode(body)) { error in
            guard case let TransportError.malformedResponse(detail) = error else {
                return XCTFail("expected .malformedResponse, got \(error)")
            }
            // The body is quoted, not described — a reader needs the operand.
            XCTAssertTrue(detail.contains("502"), "detail should quote the body: \(detail)")
        }
    }

    /// A JSON array is valid JSON and not a reply. Distinct from the non-JSON
    /// arm so the two decode failures cannot be satisfied by one branch.
    func testJSONArrayBodyThrowsMalformed() {
        let body = "[1,2,3]".data(using: .utf8)!
        XCTAssertThrowsError(try HTTPTransport.decode(body))
    }

    /// `response` present but not a string. A number here would otherwise
    /// crash an `as!` or silently stringify.
    func testNonStringResponseFieldThrows() {
        let body = #"{"response":42}"#.data(using: .utf8)!
        XCTAssertThrowsError(try HTTPTransport.decode(body))
    }

    // MARK: - Excerpt bound

    /// A gateway error page can be a megabyte of HTML and the transcript is
    /// the surface an operator reads. The bound is on the *excerpt*, not on
    /// the message, so the ellipsis is proof the cut happened.
    func testExcerptIsBoundedAndMarksTruncation() {
        let long = String(repeating: "A", count: 5_000).data(using: .utf8)!
        let text = HTTPTransport.excerpt(long, limit: 200)
        XCTAssertEqual(text.count, 201, "200 chars + ellipsis")
        XCTAssertTrue(text.hasSuffix("…"))
    }

    /// A short body is quoted whole with no ellipsis — the marker must mean
    /// something, so it cannot be unconditional.
    func testShortExcerptIsNotMarkedTruncated() {
        let text = HTTPTransport.excerpt("short".data(using: .utf8)!, limit: 200)
        XCTAssertEqual(text, "short")
        XCTAssertFalse(text.hasSuffix("…"))
    }

    /// An empty body is the shape a refused connection or a HEAD-like response
    /// produces. `""` in an error message reads as a missing message.
    func testEmptyBodyExcerptIsNamed() {
        XCTAssertEqual(HTTPTransport.excerpt(Data()), "<empty body>")
    }

    // MARK: - Error surfacing

    /// Each arm must name a DIFFERENT repair. This asserts they are distinct
    /// strings rather than that each contains a keyword — a keyword check
    /// passes even if two arms produce the same sentence.
    func testTransportErrorArmsAreDistinguishable() throws {
        let arms: [TransportError] = [
            .unconfigured,
            .misconfigured(detail: "d"),
            .unreachable(host: "h", detail: "d"),
            .httpStatus(code: 401, body: "b"),
            .malformedResponse(detail: "d"),
        ]
        let messages = arms.map { $0.errorDescription ?? "" }
        XCTAssertEqual(Set(messages).count, arms.count,
                       "two arms produced the same sentence: \(messages)")
        for message in messages {
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// The status code is carried into the sentence. A 401 and a 502 are
    /// different operator actions and folding both into "gateway refused"
    /// sends the reader to the wrong repair.
    func testHTTPStatusErrorNamesTheCode() throws {
        let message = try XCTUnwrap(
            TransportError.httpStatus(code: 401, body: "unauthorized").errorDescription)
        XCTAssertTrue(message.contains("401"), message)
        let other = try XCTUnwrap(
            TransportError.httpStatus(code: 502, body: "unauthorized").errorDescription)
        XCTAssertNotEqual(message, other, "code must vary the sentence")
    }

    /// The unreachable arm names the host. Vacuity guard: the assertion would
    /// pass against a constant sentence, so a second host must produce a
    /// different string.
    func testUnreachableErrorNamesTheHost() throws {
        let a = try XCTUnwrap(
            TransportError.unreachable(host: "10.0.0.5", detail: "refused").errorDescription)
        let b = try XCTUnwrap(
            TransportError.unreachable(host: "10.0.0.9", detail: "refused").errorDescription)
        XCTAssertTrue(a.contains("10.0.0.5"), a)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Transport selection

    /// `.resolved` now yields the real client. This is the leg that would have
    /// failed before this cut, and it is the one that fails if the arm is ever
    /// reverted to a stub.
    func testResolvedConfigYieldsHTTPTransport() {
        let transport = makeTransport(for: .resolved(endpoint("http://10.0.0.5:8080")))
        XCTAssertTrue(transport is HTTPTransport,
                      "resolved config must produce the real client, got \(type(of: transport))")
    }

    /// The other two arms must NOT produce an HTTP client. Without these, the
    /// leg above is satisfied by a `makeTransport` that returns
    /// `HTTPTransport` unconditionally.
    func testAbsentAndMalformedDoNotYieldHTTPTransport() {
        XCTAssertFalse(makeTransport(for: .absent) is HTTPTransport)
        let bad = GatewayConfig.malformed(raw: "ftp://x", reason: .unsupportedScheme)
        XCTAssertFalse(makeTransport(for: bad) is HTTPTransport)
    }

    /// The token reaches the transport. A dropped token produces a 401 that
    /// reads like a *wrong* credential rather than a missing one.
    func testEndpointTokenIsCarriedIntoTheTransport() throws {
        let transport = try XCTUnwrap(
            makeTransport(for: .resolved(endpoint("http://h:1", token: "abc")))
                as? HTTPTransport)
        XCTAssertEqual(transport.endpoint.token, "abc")
    }

    // MARK: - Session id box

    func testSessionIDBoxStartsEmptyAndTakesFirstValue() {
        let box = HTTPTransport.SessionIDBox()
        XCTAssertNil(box.current)
        box.set("s1")
        XCTAssertEqual(box.current, "s1")
    }

    /// A reply that omits `session_id` must not erase the one already held —
    /// the next turn would silently start a new server-side session and the
    /// transcript would keep scrolling as if context were intact.
    func testSessionIDBoxIgnoresNilAndEmpty() {
        let box = HTTPTransport.SessionIDBox("s1")
        box.set(nil)
        XCTAssertEqual(box.current, "s1")
        box.set("")
        XCTAssertEqual(box.current, "s1")
    }
}
