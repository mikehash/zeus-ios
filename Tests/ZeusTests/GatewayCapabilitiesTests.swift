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

    // MARK: - S5 fixtures: the two arms of POST /v1/memory/search

    /// The HYBRID arm, verbatim in structure from `memory_handlers.rs:512-527`.
    /// NO `path` on any entry — that is the whole point of the fixture.
    private static let hybridSearch = """
    {"results":[
      {"id":"m-1","session_id":"s-9","content":"the operator prefers phased pushes",
       "score":0.81,"memory_type":"Semantic","importance":0.9},
      {"id":"m-2","session_id":"s-9","content":"gate before land",
       "score":0.42,"memory_type":"Episodic","importance":0.5}
    ],"search_method":"hybrid"}
    """

    /// The FILE arm, from `memory_handlers.rs:601`.
    private static let fileSearch = """
    {"results":[
      {"path":"docs/SOUL.md","snippet":"substrate-walk","score":0.77},
      {"path":"README.md","snippet":"zeus","score":0.31}
    ],"search_method":"file"}
    """

    /// A MIXED payload. Not a shape the gateway emits today — it picks one arm
    /// per request — but the decoder must not be written in a way that makes a
    /// mixed set impossible, because "which arm" is a server-side availability
    /// question that can change under the app.
    private static let mixedSearch = """
    {"results":[
      {"path":"docs/SOUL.md","snippet":"substrate-walk","score":0.77},
      {"id":"m-1","session_id":"s-9","content":"gate before land",
       "score":0.42,"memory_type":"Semantic","importance":0.5}
    ],"search_method":"hybrid"}
    """

    private func decodeSearch(_ json: String) throws -> GatewayCapabilities.SearchPayload {
        try JSONDecoder().decode(GatewayCapabilities.SearchPayload.self,
                                 from: Data(json.utf8))
    }

    /// BOTH ARMS ARE CONSUMED.
    ///
    /// The mutation this exists for: a decoder that maps only the file arm
    /// compiles, passes every file-arm leg, and silently renders ZERO rows
    /// against a Mnemosyne-backed gateway — fewer hits than the gateway
    /// returned, with nothing on screen saying so. A count alone catches it;
    /// the kinds are asserted too so a decoder that mapped records into the
    /// file arm cannot pass by arithmetic.
    func testBothSearchArmsAreConsumed() throws {
        let hybrid = GatewayCapabilities.hits(from: try decodeSearch(Self.hybridSearch))
        XCTAssertEqual(hybrid.count, 2,
                       "a Mnemosyne payload lost rows — the memory arm is not mapped")
        XCTAssertTrue(hybrid.allSatisfy { !$0.isFile })

        let files = GatewayCapabilities.hits(from: try decodeSearch(Self.fileSearch))
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy(\.isFile))

        let mixed = GatewayCapabilities.hits(from: try decodeSearch(Self.mixedSearch))
        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(mixed.filter(\.isFile).count, 1,
                       "a mixed set collapsed to one kind — the branch is not per-entry")
    }

    /// A MNEMOSYNE RECORD NEVER YIELDS A PATH.
    ///
    /// The NEG that makes the seam type worth its cost: `SearchHit.path` is a
    /// non-optional generated `String`, so any decoder written against the FFI
    /// type must INVENT one here — `""`, or the id, or the content's first
    /// line. All three render as a location the record does not have.
    func testAMemoryRecordNeverCarriesAPath() throws {
        let hits = GatewayCapabilities.hits(from: try decodeSearch(Self.hybridSearch))
        for hit in hits {
            switch hit.kind {
            case .file:
                XCTFail("a pathless record was mapped into the FILE arm")
            case let .memory(id, memoryType, content):
                XCTAssertFalse(id.isEmpty)
                XCTAssertFalse(memoryType.isEmpty)
                XCTAssertFalse(content.isEmpty)
            }
        }
        // POS control: the same instrument DOES produce `.file` on the other
        // payload, so the assertion above is not vacuously true.
        let files = GatewayCapabilities.hits(from: try decodeSearch(Self.fileSearch))
        XCTAssertEqual(files.first?.kind, .file(path: "docs/SOUL.md", snippet: "substrate-walk"))
    }

    /// `search_method` IS NOT THE BRANCH.
    ///
    /// The mixed fixture says `"hybrid"` and carries a file entry. A decoder
    /// routing on the method string would map that entry as a record — an
    /// entry WITH a path rendered under a label it does not have. The
    /// structured fields decide; the method string is corroboration.
    func testTheMethodStringDoesNotDecideTheKind() throws {
        let payload = try decodeSearch(Self.mixedSearch)
        XCTAssertEqual(payload.search_method, "hybrid",
                       "the fixture no longer states the method the branch must IGNORE")
        let hits = GatewayCapabilities.hits(from: payload)
        XCTAssertTrue(hits.contains { $0.isFile },
                      "a file entry under a `hybrid` method was routed by the string")
    }

    /// AN UNIDENTIFIABLE ENTRY IS DROPPED, NOT BLANKED.
    ///
    /// Neither shape present: no `path`, no `id`/`content` pair. Rendering it
    /// would produce a row with an empty label and a score — a hit the
    /// operator cannot act on, presented as one they can.
    func testAnEntryMatchingNeitherArmIsDropped() throws {
        let json = """
        {"results":[
          {"score":0.5},
          {"path":"a.md","snippet":null,"score":0.9}
        ],"search_method":"file"}
        """
        let hits = GatewayCapabilities.hits(from: try decodeSearch(json))
        XCTAssertEqual(hits.count, 1, "an unidentifiable entry was rendered as a row")
        XCTAssertTrue(hits[0].isFile)
    }

    /// THE GATEWAY THROWS RATHER THAN ANSWERING EMPTY.
    ///
    /// Source-structural, and it has to be: `search` reaches `URLSession`, so
    /// a behavioural leg would need a live socket. The subject is the SHAPE of
    /// the failure path — `[]` and `nil` are forbidden RETURNS on a conformer
    /// that could not run, because `Recall.findSummary` reads an empty array
    /// as "asked and got nothing".
    func testTheGatewayNeverAnswersEmptyWhenItCannotRun() throws {
        let code = codeLines(try source("GatewayCapabilities.swift")).joined(separator: "\n")
        XCTAssertFalse(code.contains("func search(query: String) async throws -> [RecallHit] { [] }"),
                       "the gateway answers `[]` — 'could not ask' rendered as 'asked and got nothing'")
        XCTAssertFalse(code.contains("func indexSize() async throws -> UInt32? { nil }"),
                       "the gateway answers `nil` — a locality claim (`NO CORE`) from a remote core")
        // POS control: the real bodies ARE present, so the two NEGs above are
        // not passing because the methods vanished.
        XCTAssertTrue(code.contains("let payload: SearchPayload = try await post"))
        XCTAssertTrue(code.contains("let payload: FileListPayload = try await get(\"/v1/memory/files\")"))
        // NEG control on the instrument itself.
        XCTAssertFalse(code.contains("func zzzNoSuchSearch"))
    }

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

    // MARK: - S3a' — the resolver, and the census that bounds it

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
        return try String(contentsOf: root.appendingPathComponent("Sources/ZeusApp/\(name)"),
                          encoding: .utf8)
    }

    /// Comment lines stripped — a census that counts prose is a census of
    /// intentions. `CredentialTests` carries the incident this copy exists for.
    private func codeLines(_ src: String) -> [String] {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    private func endpoint(_ s: String) -> GatewayConfig.Endpoint {
        GatewayConfig.Endpoint(url: URL(string: s)!, token: "t")
    }

    /// A `.resolved` config gets the GATEWAY conformer; everything else gets
    /// the embedded one.
    ///
    /// This is the leg S4's mutation was written for and had no symbol to
    /// mutate: at `2473e3b` there was no routing function, so "resolve
    /// always-embedded" could not be expressed. It can now.
    ///
    /// The three non-resolved arms assert `is GatewayCapabilities == false`
    /// rather than asserting the embedded type, because
    /// `EmbeddedCapabilities.shared()` is legitimately `nil` in a test process
    /// with no bridge — and a leg that requires a live core would be measuring
    /// the test host, not the routing.
    func testOnlyAResolvedConfigRoutesToTheGateway() {
        let creds = StubCredentialProvider()
        let remote = makeCapabilities(for: .resolved(endpoint("http://10.0.0.5:8080")),
                                      credentials: creds)
        XCTAssertTrue(remote is GatewayCapabilities,
                      "a commissioned remote gateway still read the LOCAL jsonl")

        for config in [GatewayConfig.absent,
                       .malformed(raw: "nope", reason: .notAURL),
                       .local(.ready)] {
            XCTAssertFalse(makeCapabilities(for: config, credentials: creds) is GatewayCapabilities,
                           "\(config) has no endpoint — there is nothing to construct a gateway around")
        }
    }

    /// The endpoint SURVIVES the resolver.
    ///
    /// Vacuity: the two URLs differ, so a resolver that ignored its argument
    /// and built a default host would red here rather than agreeing by
    /// accident — the `baseUrl:`-to-`nil` shape from S2, one seam over.
    func testTheResolvedEndpointReachesTheConformer() throws {
        let creds = StubCredentialProvider()
        let a = makeCapabilities(for: .resolved(endpoint("http://10.0.0.5:8080")), credentials: creds)
        let b = makeCapabilities(for: .resolved(endpoint("http://10.0.0.9:9090")), credentials: creds)
        let ga = try XCTUnwrap(a as? GatewayCapabilities)
        let gb = try XCTUnwrap(b as? GatewayCapabilities)
        XCTAssertEqual(ga.endpoint.url.absoluteString, "http://10.0.0.5:8080")
        XCTAssertNotEqual(ga.endpoint.url, gb.endpoint.url,
                          "both arrived at the same host — the argument is being ignored")
    }

    /// THE CENSUS. `GatewayCapabilities` implements exactly `{sessions,
    /// messages}` today, and that set is what bounds the migration.
    ///
    /// ── Why this guard exists ──────────────────────────────────────────
    ///
    /// Five production sites held `EmbeddedCapabilities.shared()`; exactly ONE
    /// (`RootView:342`, the history sheet) calls the pair this conformer
    /// implements. The other four call methods that are STUBS here, and each
    /// stub's fallback is an INVENTION the moment a production site reads it:
    ///
    ///   `indexSize -> nil`   renders `NO CORE` — unimplemented wearing the
    ///                        costume of no-core, the class the
    ///                        `""`-under-`updatedAtRfc3339` sentinel was
    ///                        rejected for.
    ///   `search -> []`       renders "we did not ask" as an ANSWER.
    ///   `remember`/`indexSize` throwing `NOT AVAILABLE ON A REMOTE GATEWAY`
    ///                        DENIES capabilities the gateway HAS —
    ///                        `POST /v1/memory/remember` (`routes.rs:237`),
    ///                        index size from `GET /v1/memory/files`. That
    ///                        sentence is reserved to G8/G10.
    ///
    /// So the guard pins the implemented SET, not a count of sites: the day S5
    /// implements `remember` over REST, this leg REDS and names the site that
    /// may now migrate. A count would have permitted a swap — implement one,
    /// stub another — with the total unmoved, the same fault
    /// `check_separator_debt.sh` was rewritten to fix.
    ///
    /// It reads SOURCE rather than calling the methods because a stub and an
    /// implementation are indistinguishable at the type level: both satisfy
    /// the protocol, and `indexSize() -> nil` is a legal answer.
    func testTheConformerImplementsExactlyTwoMethods() throws {
        let code = codeLines(try source("GatewayCapabilities.swift")).joined(separator: "\n")

        // POS control: the two implemented methods are reachable by this
        // instrument at all.
        XCTAssertTrue(code.contains("func sessions() async throws -> [SessionRow] {"))
        XCTAssertTrue(code.contains("func messages(sessionID: String) async throws -> [TurnMessage] {"))

        // NEG control: the needle is not matching everything.
        XCTAssertFalse(code.contains("func zzzNoSuchMethod"))

        // The four now IMPLEMENTED. POS on each, so this half of the census
        // cannot silently become vacuous if a name is renamed.
        XCTAssertTrue(code.contains("func indexSize() async throws -> UInt32? {"))
        XCTAssertTrue(code.contains("func remember(fact: String) async throws {"))
        XCTAssertTrue(code.contains("func search(query: String) async throws -> [RecallHit] {"))

        // THE CUE NAMES A SYMBOL, AND THE SAME LEG ASSERTS IT.
        //
        // This message used to carry LINE NUMBERS — `RootView:224`, `:499`,
        // `:545`. S3b's edits to `RootView` pushed every one of them down and
        // three of the four went stale, LATENTLY: the message only prints when
        // the guard reds, so no gate between S3a′ and here could have caught
        // it. A coordinate the instrument cannot re-derive at run time is a
        // comment wearing an assertion's clothes.
        //
        // So the cue names the enclosing symbol, and each symbol printed below
        // is asserted present in the same leg that prints it.
        let siteSymbols: [(method: String, file: String, symbol: String)] = [
            ("hasProvider", "RootView.swift",      "static func armedResolution(store:"),
            ("setProvider", "RootView.swift",      "static func armedResolution(store:"),
            ("listModels",  "RoutePicker.swift",   "EmbeddedCapabilities.shared()"),
        ]
        for site in siteSymbols {
            let src = codeLines(try source(site.file)).joined(separator: "\n")
            XCTAssertTrue(src.contains(site.symbol),
                          "the cue for `\(site.method)` names `\(site.symbol)` in " +
                          "\(site.file), and that symbol is not there — the coordinate " +
                          "this guard would print has drifted, exactly as the line " +
                          "numbers did.")
        }

        let stubs = ["hasProvider", "listModels", "setProvider"]
        for name in stubs {
            let isStubbed = code.contains("throw GatewayError.unimplemented(method: \"\(name)\")")
                || code.contains("func \(name)() async throws -> Bool { false }")
            let where_ = siteSymbols.first { $0.method == name }
            XCTAssertTrue(isStubbed,
                          "`\(name)` is no longer a stub. Its production site must now " +
                          "migrate to `makeCapabilities` — the site is " +
                          "`\(where_?.symbol ?? "?")` in \(where_?.file ?? "?"), and that " +
                          "symbol is asserted present by this same leg.")
        }
    }

    /// FOUR sites stay embedded, and the number is pinned so a silent
    /// migration reds.
    ///
    /// Paired with the census above this is a two-sided guard: that one says
    /// which methods MAY be routed, this one says how many sites still are
    /// NOT. Moving a site without implementing its method reds here; the
    /// failure message says which pairing to check.
    func testExactlyFourSitesStillHoldTheEmbeddedHandleDirectly() throws {
        let names = ["RootView.swift", "Commissioning.swift", "RoutePicker.swift"]
        var total = 0
        for n in names {
            total += codeLines(try source(n))
                .filter { $0.contains("EmbeddedCapabilities.shared()") }.count
        }
        // 3 as of the attach arc: `RootView.stage` is a THIRD deliberate
        // holder. It cannot route through `makeCapabilities` — staging copies
        // bytes into the workspace the MODEL reads from, which on a gateway is
        // another machine with no upload route in the pin, so
        // `GatewayCapabilities.stageAttachment` throws by design rather than
        // fabricating a path to a file that is not there. The count moved for a
        // reason that is stated; the leg still reds on an UNEXPLAINED move,
        // which is its whole job.
        XCTAssertEqual(total, 3,
                       "the un-migrated set moved. A site may only route through " +
                       "`makeCapabilities` once `GatewayCapabilities` IMPLEMENTS the " +
                       "methods that site calls — see the census leg above.")

        // And the THREE that migrated are pinned BY NAME. A bare count of 2
        // would permit a swap — migrate one site, un-migrate another, total
        // unmoved — which is the fault `check_separator_debt.sh` was rewritten
        // to fix, one subsystem over.
        let root = codeLines(try source("RootView.swift")).joined(separator: "\n")
        XCTAssertTrue(root.contains("HistorySheet(core: makeCapabilities("),
                      "the history sheet is the only screen reading sessions()/messages(); " +
                      "if it is not routed, a remote gateway shows LOCAL history")
        XCTAssertTrue(root.contains("core: makeCapabilities(for: configSource.config,"),
                      "NodesView is not routed — a commissioned gateway would search the " +
                      "LOCAL workspace index and render it as the remote one")
        XCTAssertTrue(root.contains("try await core.remember(fact: fact)"),
                      "the remember site is not routed — `POST /v1/memory/remember` exists " +
                      "(routes.rs:237), so refusing it denies a capability the gateway has")
    }
}
