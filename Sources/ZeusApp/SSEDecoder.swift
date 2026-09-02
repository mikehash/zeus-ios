import Foundation

// MARK: - Stage 1 — frame reassembly

/// One reassembled SSE event, before anything looks at its payload.
///
/// This type exists so that "a comment frame arrived", "a fragmented frame
/// arrived" and "an unknown event name arrived" are three DIFFERENT facts. A
/// single-stage decoder — bytes straight to `SessionFrame` — reports all three
/// as "bad JSON", which is the failure vocabulary of the layer that happens to
/// throw rather than the layer that is actually wrong.
struct SSEEvent: Equatable {
    /// The `data:` field(s), rejoined with `\n` in arrival order. `nil` when the
    /// event carried no `data` field at all — a keepalive comment, or an event
    /// with only `id:`/`retry:` fields. Such an event MUST be ignored, never
    /// parsed.
    let data: String?

    /// The `event:` field, if the server set one. Against this gateway it is
    /// always `nil`: `.event(` = 0 sites vs `.data(` = 17 at `2dc487bde`, so all
    /// seven names ride inside the JSON body. Carried anyway because a decoder
    /// that cannot even represent the transport's own name field is one that
    /// silently mis-reads a conformant server.
    let name: String?

    var isComment: Bool { data == nil && name == nil }
}

/// Incremental SSE frame reader: bytes in, whole events out.
///
/// ## Why this is buffered rather than a `split`
///
/// `URLSession.bytes` hands over chunks at arbitrary boundaries — a chunk is a
/// TCP-shaped quantity, not an SSE-shaped one. A single event can arrive in two
/// pieces and two events can arrive in one. Any reader that treats "a chunk
/// arrived" as "an event arrived" works on every short reply and fails on the
/// long ones, which are exactly the turns worth streaming.
///
/// ## Three tolerances, each one measured rather than assumed
///
/// **① Comment frames.** `chat_handlers.rs:553` (and `:1166`, `:1287` — all
/// three `Sse::new` sites on that file) carry `.keep_alive(KeepAlive::default())`.
/// axum's default is `event = b":\n\n"` at a `15s` interval, and it is byte
/// identical in the two axum majors `zeus-api` links (0.6.20 at `sse.rs:196`,
/// 0.7.9 at `sse.rs:188`). The device route's own turn budget is `1800` seconds
/// (`chat_handlers.rs:508`). A bare `:` frame every 15 seconds of silence is
/// therefore the COMMON case on a long cook, not an edge case — a decoder that
/// JSON-parses every frame throws first on the most important turns.
///
/// **② The space after `data:` is optional per spec.** Measured on this gateway:
/// `^data: ` × 3, `^data:[^ ]` × 0 — so a fixed six-byte strip works HERE and
/// breaks against a conformant server. The Rust twin ships the strict form at 14
/// sites; `strip_prefix` is used here rather than an offset because at those
/// sites the strict predicate is also what guarantees `line.len() >= 6`, and
/// loosening it without changing the strip is an index-out-of-bounds panic on a
/// legal five-byte `data:` line.
///
/// **③ Multi-line data.** `Event::data()` splits its argument on `\n` and emits
/// one `data:` line per fragment (axum `sse.rs`, both majors). Today the
/// payloads are `json!().to_string()` — compact, so N == 1 and a one-line-per-
/// event reader is correct BY COINCIDENCE. Any pretty-print upstream turns every
/// frame into fragments; the Rust twin has 0 of 14 sites that rejoin, so it
/// would parse the first line and `continue` past the rest. Two lines now or a
/// mystery later.
///
/// **CR.** Measured 0 CR bytes on this server, but `\r\n` is the spec's own
/// separator, so every line is CR-trimmed. The cost of tolerating it is one
/// call; the cost of not is a terminator that never fires while tokens keep
/// flowing, because `\r` is JSON whitespace and the payload still parses.
struct SSEFrameReader {

    /// The buffer is BYTES, not `String`, and that is load-bearing.
    ///
    /// In Swift `"\r\n"` is a SINGLE `Character` — one extended grapheme
    /// cluster — so `String.range(of: "\n\n")` **cannot match across a CRLF**
    /// and a CRLF-framed stream yields zero events while the buffer grows
    /// without bound. That reads as a hang, not as an error, and it is
    /// invisible at every layer above. The first draft of this file was a
    /// `String` search and the CRLF leg is what found it.
    private var buffer: [UInt8] = []

    /// Feed a decoded chunk. Returns every event that COMPLETED in this chunk;
    /// a trailing partial event stays in the buffer for the next call.
    mutating func feed(_ chunk: String) -> [SSEEvent] {
        buffer.append(contentsOf: Array(chunk.utf8))
        var out: [SSEEvent] = []
        while let cut = Self.terminator(in: buffer) {
            let block = String(decoding: buffer[buffer.startIndex..<cut.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<cut.upperBound)
            if let event = Self.parseBlock(block) { out.append(event) }
        }
        return out
    }

    /// Flush a final event that arrived without its terminating blank line.
    /// A server closing the socket after the last frame is legal and common —
    /// and on this route the last frame is `done`, which carries the entire
    /// reply, so dropping it loses the answer rather than a trailing newline.
    mutating func finish() -> [SSEEvent] {
        let rest = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        guard let event = Self.parseBlock(rest) else { return [] }
        return [event]
    }

    /// The EARLIEST blank-line terminator, in either spelling (`\n\n` or
    /// `\r\n\r\n`). Earliest and not first-found: a buffer holding an LF event
    /// followed by a CRLF one must cut at the LF, and searching one spelling
    /// alone would cut past a whole event.
    static func terminator(in bytes: [UInt8]) -> Range<Int>? {
        let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D
        var i = 0
        while i < bytes.count {
            if bytes[i] == LF, i + 1 < bytes.count, bytes[i + 1] == LF {
                return i..<(i + 2)
            }
            if bytes[i] == CR, i + 3 < bytes.count,
               bytes[i + 1] == LF, bytes[i + 2] == CR, bytes[i + 3] == LF {
                return i..<(i + 4)
            }
            i += 1
        }
        return nil
    }

    /// Parse one already-delimited block. `nil` for a block with no fields at
    /// all (the whitespace between events); a comment-only block returns an
    /// event with `data == nil`, which is a DIFFERENT fact from "no block".
    static func parseBlock(_ block: String) -> SSEEvent? {
        var fragments: [String] = []
        var name: String?
        var sawField = false

        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingTrailingCR()
            if line.isEmpty { continue }

            // A line beginning `:` is a comment. This is the keepalive.
            if line.hasPrefix(":") { sawField = true; continue }

            guard let colon = line.firstIndex(of: ":") else {
                // Field name with no value, e.g. a bare `data`. Legal: value is "".
                if line == "data" { fragments.append(""); sawField = true }
                continue
            }
            let field = String(line[line.startIndex..<colon])
            var value = String(line[line.index(after: colon)...])
            // ONE optional leading space is stripped, per spec. Not six bytes,
            // and not `trimmingCharacters` — a payload may legitimately begin
            // with whitespace that is data, and only the first space is framing.
            if value.hasPrefix(" ") { value.removeFirst() }

            switch field {
            case "data":  fragments.append(value); sawField = true
            case "event": name = value;            sawField = true
            case "id", "retry": sawField = true
            default: sawField = true   // unknown field: ignore per spec, not an error
            }
        }

        guard sawField else { return nil }
        return SSEEvent(data: fragments.isEmpty ? nil : fragments.joined(separator: "\n"),
                        name: name)
    }
}

private extension String {
    func trimmingTrailingCR() -> String {
        hasSuffix("\r") ? String(dropLast()) : self
    }
}

// MARK: - Stage 2 — payload

/// What went wrong BELOW the seven names.
///
/// Separate from `TransportError` on purpose: these are decoder facts, and
/// collapsing them into the transport's vocabulary is how "the gateway is
/// broken" gets reported for "this build is one name out of date".
enum SSEDecodeError: Error, Equatable {
    /// The payload was not a JSON object.
    case notJSON(excerpt: String)
    /// A JSON object with no `event` key. The frame is structurally foreign.
    case noEventField(excerpt: String)
    /// A known-shaped frame whose name this build does not have an arm for.
    /// Carries the name so the log names the WIRE's vocabulary, not ours.
    case unknownEvent(name: String)
    /// The name is one of the seven and a field it needs is absent. This is the
    /// arm that would have caught `tool_end`'s fabricated `ok:` if a test had
    /// ever seen a payload byte.
    case missingField(event: String, field: String)
}

/// What the decoder decided about one event.
enum SSEDecodeOutcome: Equatable {
    /// A frame for the engine.
    case frame(SessionFrame)
    /// Ignored, deliberately, with the reason recorded. Keepalives land here —
    /// and so does `[DONE]` (see `Policy`). An ignore that is INDISTINGUISHABLE
    /// from a decode failure is how a silent stream gets debugged twice.
    case ignored(reason: IgnoreReason)

    enum IgnoreReason: Equatable {
        /// No `data` field: keepalive comment or a fields-only event.
        case noData
        /// The literal `[DONE]` sentinel.
        ///
        /// Written as an EXPLICIT arm rather than an omission so the next reader
        /// sees the route split was DECIDED. `[DONE]` hits in the device_chat
        /// block (`chat_handlers.rs:505-555`) = 0; in the OpenAI-compat block
        /// = 2 (`:1162`, `:1283`). Our own Rust client REQUIRES it at
        /// `zeus-llm/src/lib.rs:2833`, `:3898` and `codex.rs:261` — so the
        /// sentinel is mandatory on the routes that send it and never arrives on
        /// this one. A client that DEMANDS it hangs here; one that CHOKES on it
        /// breaks there. Tolerated, non-terminating, never required.
        case doneSentinel
    }
}

/// Maps one reassembled event onto the seven in-band names.
///
/// The names are read from the corpus, not from prose: a whole-file census of
/// `chat_handlers.rs` gives `thinking 4 · error 2 · iter 2 · tool_end 2 ·
/// tool_start 2 · token 1 · done 1` (POS ctl `json!` = 25, NEG ctl 0). The
/// handler's own doc comment at `:425-426` lists FIVE, omitting `iter` and
/// `error` — a decoder built from that prose drops a progress frame and renders
/// a real agent failure as an unknown frame.
enum SessionFrameDecoder {

    static func decode(_ event: SSEEvent) -> Result<SSEDecodeOutcome, SSEDecodeError> {
        guard let payload = event.data else {
            return .success(.ignored(reason: .noData))
        }
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            return .success(.ignored(reason: .doneSentinel))
        }

        guard let bytes = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        else { return .failure(.notJSON(excerpt: excerpt(payload))) }

        guard let name = object["event"] as? String else {
            return .failure(.noEventField(excerpt: excerpt(payload)))
        }

        func string(_ key: String) -> Result<String, SSEDecodeError> {
            guard let v = object[key] as? String else {
                return .failure(.missingField(event: name, field: key))
            }
            return .success(v)
        }

        switch name {
        case "token":
            return string("text").map { .frame(.token($0)) }
        case "thinking":
            return string("text").map { .frame(.thinking($0)) }
        case "tool_start":
            // The wire key is `tool`, not `name`. Read from
            // `chat_handlers.rs`, whose producer is
            // `StreamChunk::ToolStart { name }` — the JSON key and the Rust
            // field disagree, which is exactly the kind of thing a Swift-
            // constructed test fixture cannot notice.
            return string("tool").map { .frame(.toolStart(name: $0)) }
        case "tool_end":
            switch string("tool") {
            case let .failure(e): return .failure(e)
            case let .success(tool):
                return string("output").map { .frame(.toolEnd(name: tool, output: $0)) }
            }
        case "iter":
            guard let n = object["n"] as? Int else {
                return .failure(.missingField(event: name, field: "n"))
            }
            return .success(.frame(.iteration(n)))
        case "done":
            // `done` CARRIES THE REPLY. It is not a terminator with an empty
            // body: `Ok(text) => json!({"event":"done","text":text})`, and on the
            // no-token path (`inbox.rs:1098`, an asserted contract whose every
            // non-`Done` arm panics) it is the SOLE carrier. The engine REPLACES
            // on this frame; see `SessionEngine.absorb`.
            return string("text").map { .frame(.done($0)) }
        case "error":
            // The Err arm carries `error` and NO `text` key at all
            // (`chat_handlers.rs:541-543`). So on this frame the accumulated
            // tokens are the only carrier of a partial reply, which is why the
            // engine keeps them and appends the reason rather than replacing.
            return string("error").map { .frame(.failure($0)) }
        default:
            return .failure(.unknownEvent(name: name))
        }
    }

    /// Bounded quote. A gateway that answers 200 with an HTML error page can
    /// send a megabyte, and the excerpt lands in a transcript an operator reads.
    static func excerpt(_ s: String, limit: Int = 200) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "<empty payload>" }
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }
}
