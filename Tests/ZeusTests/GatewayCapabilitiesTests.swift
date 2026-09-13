import XCTest
@testable import Zeus

/// S3a — legs for the remote conformer's decode and its `call_id → id` join.
///
/// ── What these legs can and cannot see ─────────────────────────────────
///
/// Every fixture here is a payload built by hand from the SHAPE emitted by
/// `build_replay_entry` at `8e19318c`, not a response captured from a running
/// gateway. No leg in this file opens a socket. A wire-shape change on the
/// Zeus side would leave all of them green and break the phone — that is a
/// phone observation, stated in `docs/2026-09-1x-remote-gateway-parity.md` §9
/// and repeated here so it is visible at the site.
final class GatewayCapabilitiesTests: XCTestCase {

    // MARK: - fixture 1: a tool-calling turn

    /// The three-entry shape a tool call actually produces, verbatim in
    /// structure from `build_replay_entry`:
    ///
    ///   - the user's prose        — all three tool fields `null`
    ///   - the assistant's call    — `tool_calls` populated, `tool_name` an ARRAY
    ///   - the tool's result       — `content` EMPTY, `tool_name` null,
    ///                               `tool_results[].call_id` the only link back
    private static let toolTurn = """
    {"entries":[
      {"index":0,"timestamp":"2026-09-11T04:00:00Z","role":"user",
       "content":"list the files in my workspace",
       "tool_calls":null,"tool_name":null,"tool_results":null,
       "thinking":null,"token_count":7},
      {"index":1,"timestamp":"2026-09-11T04:00:01Z","role":"assistant",
       "content":"",
       "tool_calls":[{"id":"call_abc","name":"list_dir","arguments":"{}"}],
       "tool_name":["list_dir"],"tool_results":null,
       "thinking":null,"token_count":3},
      {"index":2,"timestamp":"2026-09-11T04:00:02Z","role":"tool",
       "content":"",
       "tool_calls":null,"tool_name":null,
       "tool_results":[{"call_id":"call_abc","success":true,"output":"a.txt"}],
       "thinking":null,"token_count":4}
    ]}
    """

    /// A prose-only session: all three tool fields `null` on every entry.
    private static let proseOnly = """
    {"entries":[
      {"index":0,"timestamp":"2026-09-11T04:00:00Z","role":"user",
       "content":"hello","tool_calls":null,"tool_name":null,"tool_results":null,
       "thinking":null,"token_count":1},
      {"index":1,"timestamp":"2026-09-11T04:00:01Z","role":"assistant",
       "content":"hi","tool_calls":null,"tool_name":null,"tool_results":null,
       "thinking":null,"token_count":1}
    ]}
    """

    private func decode(_ json: String) throws -> [GatewayCapabilities.ReplayEntry] {
        try JSONDecoder()
            .decode(GatewayCapabilities.ReplayPayload.self, from: Data(json.utf8))
            .entries
    }

    // MARK: - decode

    /// `[T]` WOULD FAIL HERE, ON EVERY PROSE MESSAGE.
    ///
    /// `build_replay_entry` emits `Value::Null` — not `[]` — when a message has
    /// no calls and no results (`:626`, `:632`, `:654`, all `if !is_empty` with
    /// an `else Value::Null`). A fixture built only from tool-calling turns
    /// would never have seen this, which is why the prose payload is its own
    /// leg rather than a variation of the first.
    func testAProseEntryDecodesWithAllThreeToolFieldsNull() throws {
        let entries = try decode(Self.proseOnly)
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0].tool_calls)
        XCTAssertNil(entries[0].tool_results)
        let turns = GatewayCapabilities.turns(from: entries)
        XCTAssertEqual(turns.map(\.role), ["user", "assistant"])
        XCTAssertEqual(turns.compactMap(\.toolName), [],
                       "no join source, no name — and no crash")
    }

    /// THE JOIN. The tool row's own `tool_name` is `null` and always will be —
    /// `Message::tool` sets `tool_calls: vec![]` (`lib.rs:9617`), so the field
    /// named to carry the name can never hold one on the row that needs it.
    /// The name comes from the PRECEDING assistant entry, selected by call id.
    func testTheToolNameIsJoinedFromThePrecedingAssistantEntry() throws {
        let entries = try decode(Self.toolTurn)
        // The premise, asserted rather than assumed: if this ever stops being
        // null the join is no longer load-bearing and this file should change.
        XCTAssertNil(entries[2].tool_calls)
        XCTAssertEqual(entries[2].tool_results?.first?.call_id, "call_abc")
        XCTAssertEqual(entries[2].content, "",
                       "the tool row carries NO text; the marker is all there is")

        let turns = GatewayCapabilities.turns(from: entries)
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns[2].toolName, "list_dir")
        // And it reaches the screen as the marker, through the SAME
        // `History.rows` the embedded path uses — one degrade implementation,
        // not two.
        XCTAssertEqual(History.rows(from: turns).last?.text, "[LIST_DIR]")
    }

    /// A CALL ID THAT MATCHES NOTHING DEGRADES — it never mis-attributes.
    ///
    /// The vacuity assertion is the point: `[TOOL]` must differ from the
    /// joined marker, or "degraded" and "worked" would be one screen.
    func testAnUnmatchedCallIdDegradesToTOOLRatherThanGuessing() throws {
        let broken = Self.toolTurn.replacingOccurrences(of: "\"call_id\":\"call_abc\"",
                                                        with: "\"call_id\":\"call_zzz\"")
        let turns = GatewayCapabilities.turns(from: try decode(broken))
        XCTAssertNil(turns[2].toolName)
        XCTAssertEqual(History.rows(from: turns).last?.text, "[TOOL]")
        XCTAssertNotEqual(History.rows(from: turns).last?.text, "[LIST_DIR]")
    }

    // MARK: - the conformance fixture

    /// ONE PAYLOAD, TWO IMPLEMENTATIONS, TURN BY TURN.
    ///
    /// The join exists twice — in Rust for the embedded path, in this
    /// conformer's decoder for the remote one — because `TurnMessage` has no
    /// field for a call id and the join therefore cannot happen after decode.
    /// Two implementations of one rule drift silently unless something compares
    /// them, and this is that thing: the `[TurnMessage]` the embedded path
    /// produces for this session, recorded as the expected value.
    ///
    /// ── Two carve-outs, both named rather than papered over ─────────────
    ///
    ///  1. SYSTEM TURNS. Replay emits them (`sessions.rs:622`); the bridge's
    ///     `messages()` does not (`lib.rs:1045`). The decoder drops them, and
    ///     the fixture includes one so that the drop is exercised rather than
    ///     assumed. (`History.rows` would drop it anyway through its
    ///     unknown-role arm, so this is fixture agreement, not display
    ///     correctness — a distinction worth keeping straight, because "the
    ///     screen would show the persona" is a scarier and wronger claim.)
    ///  2. REDACTION. Replay runs `redact_secrets` over content
    ///     (`sessions.rs` ×8); the bridge does not (×0). So byte-equality is
    ///     only valid on payloads with NOTHING REDACTABLE, and this fixture is
    ///     deliberately built from such content. Anyone who makes this leg red
    ///     by adding a key-shaped string to the fixture should fix the FIXTURE,
    ///     not the gateway.
    func testBothJoinImplementationsAgreeTurnByTurn() throws {
        let payload = """
        {"entries":[
          {"index":0,"timestamp":"2026-09-11T04:00:00Z","role":"system",
           "content":"you are zeus","tool_calls":null,"tool_name":null,
           "tool_results":null,"thinking":null,"token_count":3},
          {"index":1,"timestamp":"2026-09-11T04:00:01Z","role":"user",
           "content":"list the files","tool_calls":null,"tool_name":null,
           "tool_results":null,"thinking":null,"token_count":3},
          {"index":2,"timestamp":"2026-09-11T04:00:02Z","role":"assistant",
           "content":"","tool_calls":[{"id":"c1","name":"list_dir","arguments":"{}"}],
           "tool_name":["list_dir"],"tool_results":null,
           "thinking":null,"token_count":3},
          {"index":3,"timestamp":"2026-09-11T04:00:03Z","role":"tool",
           "content":"","tool_calls":null,"tool_name":null,
           "tool_results":[{"call_id":"c1","success":true,"output":"a.txt"}],
           "thinking":null,"token_count":4},
          {"index":4,"timestamp":"2026-09-11T04:00:04Z","role":"assistant",
           "content":"one file: a.txt","tool_calls":null,"tool_name":null,
           "tool_results":null,"thinking":null,"token_count":5}
        ]}
        """

        /// What the EMBEDDED path produces for this same session — the
        /// bridge's `messages()` output shape: no system turn, the tool row
        /// with an empty content and a resolved `toolName`.
        let embedded = [
            TurnMessage(role: "user", content: "list the files",
                        timestampRfc3339: "2026-09-11T04:00:01Z", toolName: nil),
            TurnMessage(role: "assistant", content: "",
                        timestampRfc3339: "2026-09-11T04:00:02Z", toolName: nil),
            TurnMessage(role: "tool", content: "",
                        timestampRfc3339: "2026-09-11T04:00:03Z", toolName: "list_dir"),
            TurnMessage(role: "assistant", content: "one file: a.txt",
                        timestampRfc3339: "2026-09-11T04:00:04Z", toolName: nil),
        ]

        let remote = GatewayCapabilities.turns(from: try decode(payload))

        XCTAssertEqual(remote.count, embedded.count,
                       "the system turn is the likely culprit if this reds")
        for (i, pair) in zip(remote, embedded).enumerated() {
            XCTAssertEqual(pair.0.role, pair.1.role, "turn \(i) role")
            XCTAssertEqual(pair.0.content, pair.1.content, "turn \(i) content")
            XCTAssertEqual(pair.0.toolName, pair.1.toolName, "turn \(i) toolName")
            XCTAssertEqual(pair.0.timestampRfc3339, pair.1.timestampRfc3339,
                           "turn \(i) timestamp")
        }
        // Vacuity: the sequences must not be trivially equal because both are
        // empty, and the tool name must actually be somewhere in there.
        XCTAssertFalse(remote.isEmpty)
        XCTAssertEqual(remote.compactMap(\.toolName), ["list_dir"])
    }

    // MARK: - the list

    /// EVERY remote row is unranked, and that is a decision about the WIRE, not
    /// a parse failure. `GET /v1/sessions` emits `created` and no `updated`.
    func testTheGatewayListHasNoSortKeyAtAll() throws {
        let json = """
        {"sessions":[{"id":"zzz","created":"2026-09-11T04:00:00Z"},
                     {"id":"aaa","created":"2026-09-11T05:00:00Z"}],"total":2}
        """
        let decoded = try JSONDecoder()
            .decode(GatewayCapabilities.SessionListPayload.self, from: Data(json.utf8))
        // THE CONFORMER'S OWN MAPPING, not a copy of it. The first version of
        // this leg re-typed `SessionRow(id:sortKey: nil)` here and passed a
        // mutation that wrote `""` in the production mapping — a test that
        // re-implements its subject detects changes only in the copy.
        let rows = GatewayCapabilities.rows(from: decoded)
        // `compactMap` alone CANNOT SEE THE SENTINEL: `[""]` compact-maps to
        // `[""]`, not `[]`, but a reader skims this as "no keys". Measured —
        // a mutation writing `sortKey: ""` at the conformer passed every other
        // leg in this file, because `""` parses to `nil` and therefore sorts
        // identically and renders identically through `ago`. The rejected
        // option (b) was INVISIBLE to the suite until this assertion existed.
        // The key must be ABSENT, not empty.
        XCTAssertEqual(rows.map(\.sortKey), [nil, nil],
                       "a sentinel is not an absence: \"\" in a field named for a "
                       + "timestamp claims the session was updated at the empty instant")
        XCTAssertEqual(rows.compactMap(\.sortKey), [],
                       "a created time under an update-time name is the costume defect")
        XCTAssertTrue(History.isServerOrder(rows))
        // Server order, not alphabetical, and the ids differ under the two so
        // the assertion can tell them apart.
        XCTAssertEqual(History.newestFirst(rows).map(\.id), ["zzz", "aaa"])
    }

    // MARK: - the states this conformer can be in

    /// 404 IS ITS OWN ARM. A route the app needs and this gateway does not
    /// serve is a parity fact with an actionable name; folded into the status
    /// arm it would read as a transient failure.
    func testTheFourErrorStatesAreFourDistinctSentences() {
        let e = GatewayCapabilities.GatewayError.self
        let sentences = [
            "\(e.endpointMissing(path: "/v1/sessions"))",
            "\(e.httpStatus(code: 401, path: "/v1/sessions"))",
            "\(e.unreachable(host: "zeus.local", detail: "timed out"))",
            "\(e.unimplemented(method: "remember"))",
        ]
        XCTAssertEqual(Set(sentences).count, 4, "two states rendering alike is one state")
        XCTAssertTrue(sentences[0].contains("/v1/sessions"))
        XCTAssertTrue(sentences[3].contains("remember"),
                      "an app limit must name the method, not blame the gateway")
    }
}
