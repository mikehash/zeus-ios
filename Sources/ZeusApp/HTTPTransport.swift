import Foundation

/// The first real wire: `POST /v1/chat` against a Zeus gateway.
///
/// ## Why one delta and not a token stream
///
/// The route this talks to is `zeus-api`'s `/v1/chat`, whose handler signature
/// is `Json<ChatRequest> -> Result<Json<ChatResponse>, _>` (chat_handlers.rs:286).
/// It returns a **whole response**, not an SSE stream — `/v1/chat/completions`
/// is the streaming, OpenAI-shaped route and is a separate cut.
///
/// So this transport yields exactly ONE delta and finishes. That is deliberate
/// and it is the honest shape: the prototype's word-by-word `setTimeout` walk
/// was a *presentation* of streaming with no sender behind it, and re-creating
/// that here — chopping a complete reply into fake deltas on a timer — would
/// reintroduce the same lie one layer lower. A caller cannot distinguish
/// "arrived in one piece" from "arrived in one piece, then diced", and the
/// second spelling makes the transcript claim a property the wire does not have.
///
/// The engine above folds frames, so a one-frame stream and an N-frame stream
/// are the same code path FOR PROSE. The rest of that sentence used to read
/// "when the SSE route lands, only this file changes" — and its own successor
/// commit refuted it: `eec3baac` typed the element and touched FIVE files
/// (Session.swift, SessionFrame.swift, HTTPTransport.swift, and two test
/// files), because the fifth site was a CONSUMER accumulating the stream into
/// a typed array, which no census of conformers can see. The prediction was
/// true when written, false one commit later, and still sitting here as prose.
/// SSE lands as a SECOND CONFORMER to `SessionTransport`, not as an edit here.
/// Holds the gateway-assigned session id between turns.
///
/// FILE SCOPE, not nested in `HTTPTransport`: the engine owns one of these and
/// hands it to whatever transport its factory builds, so the type must be
/// nameable without naming a concrete conformer. Nested, `SessionEngine.init`
/// would have to spell `HTTPTransport.SessionIDBox` — the abstract holder
/// learning one arm's name, which is exactly the coupling the existential
/// `SessionTransport` exists to prevent.
///
/// A class, not a `var` on the struct, because `SessionTransport` refines
/// `Sendable` (Session.swift:17) and a `Sendable` struct cannot hold mutable
/// value state. Reference semantics are also the point: ONE box outlives MANY
/// transports. The engine constructs a transport per turn; if the id lived in
/// the transport, every turn would open a fresh session and the gateway could
/// not tell "new conversation" from "client lost the id" — the request is
/// byte-identical either way, because `encodeBody` OMITS the key when nil.
/// Silent amnesia, no error, no red test.
///
/// Locked rather than actor-isolated so the read stays synchronous inside the
/// request builder — an `await` there would let a second turn observe a
/// half-updated id.
final class SessionIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ initial: String? = nil) { value = initial }

    var current: String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ new: String?) {
        guard let new, !new.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        value = new
    }
}

struct HTTPTransport: SessionTransport {

    let endpoint: GatewayConfig.Endpoint
    let session: URLSession

    /// Carried across turns so the gateway threads context. `nil` until the
    /// first reply names one. This is a `let` holding a reference type on
    /// purpose — the transport is `Sendable` and must not grow mutable value
    /// state that two concurrent turns could race on. Injected, never
    /// defaulted: ONE box outlives MANY transports, and the thing that must
    /// persist is held by the thing that persists (the engine).
    let sessionID: SessionIDBox

    /// `sessionID` carries NO default, deliberately. A defaulted
    /// `= SessionIDBox()` reconstructs the defect one frame out — a fresh box
    /// per construction, at a site that runs per turn — and does so invisibly,
    /// because a census of call sites cannot see a parameter nobody passes.
    /// Required, the compiler enumerates every site instead.
    init(endpoint: GatewayConfig.Endpoint,
         session: URLSession = .shared,
         sessionID: SessionIDBox) {
        self.endpoint = endpoint
        self.session = session
        self.sessionID = sessionID
    }

    // MARK: - Wire

    /// `POST /v1/chat`. Path is built by `appendingPathComponent` on the
    /// configured base so a base with or without a trailing slash resolves the
    /// same — a difference that is invisible in a config string and produces a
    /// 404 that reads like a dead gateway.
    static func chatURL(base: URL) -> URL {
        base.appendingPathComponent("v1").appendingPathComponent("chat")
    }

    func stream(prompt: String) -> AsyncThrowingStream<SessionFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await send(prompt)
                    // `/v1/chat` is NON-streaming: one whole reply, so one
                    // `.token` frame and finish. Not chopped into timed fake
                    // deltas — that is the prototype's `setTimeout` word-walk
                    // one layer lower. The engine accumulates, so a 1-frame and
                    // an N-frame stream are the same code path FOR PROSE. Telemetry
                    // frames are routed by type, not folded — see SessionFrame.
                    continuation.yield(.token(text))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the consumer cancels the request. Without this the
            // engine's `cancelTurn` would stop *reading* while the socket kept
            // running — the turn would look abandoned and still be in flight.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func send(_ prompt: String) async throws -> String {
        var request = URLRequest(url: Self.chatURL(base: endpoint.url))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = endpoint.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try Self.encodeBody(prompt: prompt,
                                               sessionID: sessionID.current)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // A transport-level failure names the host, because "the request
            // failed" sends the reader to the wrong layer. The host is already
            // in the config the operator supplied, so this leaks nothing new.
            throw TransportError.unreachable(
                host: endpoint.url.host ?? endpoint.url.absoluteString,
                detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TransportError.malformedResponse(detail: "response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TransportError.httpStatus(code: http.statusCode,
                                            body: Self.excerpt(data))
        }

        let decoded = try Self.decode(data)
        sessionID.set(decoded.sessionID)
        return decoded.response
    }

    // MARK: - Codec
    //
    // Hand-rolled rather than Codable-on-the-wire-type because the gateway's
    // ChatResponse carries fields this client does not model (`tool_calls`),
    // and a synthesised Codable would either have to enumerate them or reject
    // the payload. Decoding the two fields actually used keeps an added server
    // field from breaking the client.

    struct Reply: Equatable {
        let response: String
        let sessionID: String?
    }

    /// `{"message": ..., "session_id": ...}` — matches `ChatRequest`
    /// (required: `message`; optional: `session_id`, `stream`).
    /// `stream` is omitted rather than sent as `false`: this route does not
    /// stream, and sending the field would imply the client negotiated it.
    static func encodeBody(prompt: String, sessionID: String?) throws -> Data {
        var object: [String: Any] = ["message": prompt]
        if let sessionID, !sessionID.isEmpty { object["session_id"] = sessionID }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func decode(_ data: Data) throws -> Reply {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TransportError.malformedResponse(
                detail: "body is not JSON — \(excerpt(data))")
        }
        guard let object = any as? [String: Any] else {
            throw TransportError.malformedResponse(detail: "body is not a JSON object")
        }
        // A 200 with no `response` key is the dangerous case: it is a
        // *successful* request that produced no answer. Yielding "" would put
        // an empty agent bubble in the transcript and read as a silent reply,
        // which is exactly the stub-that-answers failure the M4 note names.
        guard let text = object["response"] as? String else {
            throw TransportError.malformedResponse(
                detail: "200 OK with no \"response\" field — \(excerpt(data))")
        }
        return Reply(response: text, sessionID: object["session_id"] as? String)
    }

    /// Bounded quote of a body for an error message. Bounded because a gateway
    /// error page can be a megabyte of HTML and the transcript is the surface
    /// an operator reads.
    static func excerpt(_ data: Data, limit: Int = 200) -> String {
        guard !data.isEmpty else { return "<empty body>" }
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "<\(data.count) bytes, not UTF-8>" }
        return data.count > limit ? text + "…" : text
    }
}
