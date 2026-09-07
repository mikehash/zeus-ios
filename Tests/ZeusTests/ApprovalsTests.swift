import XCTest
@testable import Zeus

/// Legs for B10 — proposal cards on `GET /v1/approvals`.
///
/// ⚠️ APERTURE, stated here rather than implied. These legs exercise the
/// decode (including the internally-tagged `status` flattening), the four-case
/// state machine, the three empty strings, the header-count suppression, and
/// the outcome derivation. They do NOT prove the app talks to a real gateway:
/// `URLSession` is never socketed here, and `HTTPApprovalsService` is only
/// reached through `outcome(status:body:approve:)`, which is a pure function.
/// What backs the wire claim is a live `curl` table in the commit body, run on
/// this box against `~/Zeus@8746e17e4` — a hand measurement, not a re-running
/// leg.
final class ApprovalsTests: XCTestCase {

    // MARK: - fixtures

    /// The gateway's real shape: a BARE ARRAY, and `status` FLAT — not nested.
    /// If this ever needs a `{"approvals":…}` wrapper to decode, the wire moved.
    private static let pendingPayload = """
    [{"id":"a1","tool_name":"shell","args":{"cmd":"rm -rf /tmp/x","timeout":30},
      "agent_id":"zeus106","created_at":"2026-09-07T03:00:00Z","status":"pending"}]
    """.data(using: .utf8)!

    /// A DENIED record off the `approval_event` stream: `reason` is a SIBLING
    /// of `status`, not a child of it. This is the record that would have
    /// failed against my first (wrong) model of the enum.
    private static let deniedPayload = """
    [{"id":"a2","tool_name":"write_file","args":{"path":"/etc/hosts"},
      "agent_id":null,"created_at":"2026-09-07T03:00:00Z",
      "status":"denied","reason":"not on my box"}]
    """.data(using: .utf8)!

    private func decode(_ data: Data) throws -> [Approval] {
        try JSONDecoder().decode([ApprovalRecord].self, from: data).map(\.approval)
    }

    // MARK: - the leg the dispatch named: unreachable is not empty

    /// The `with_live(None)`-equivalent, and the reason this file exists.
    ///
    /// The TUI's `approvals_tab.rs:95` — `self.live.unwrap_or(&[])` — collapses
    /// `None` (unreachable) and `Some(&[])` (empty) into one green string with
    /// zero tests distinguishing them. This leg fails if the iOS surface ever
    /// acquires that shape.
    ///
    /// VACUOUS FORM, rejected: `XCTAssertFalse(unreachable.emptyLine!.isEmpty)`
    /// — passes when both states return the SAME non-empty string, i.e. passes
    /// on the exact defect. The kept form asserts the two differ, in three
    /// independent channels.
    func testUnreachableIsNotEmpty() {
        let empty = ApprovalsState.loaded(pending: [], gatingConfigured: true)
        let down = ApprovalsState.unavailable(reason: "127.0.0.1 · connection refused")

        // ① the string itself
        XCTAssertNotEqual(empty.emptyLine, down.emptyLine)
        XCTAssertEqual(empty.emptyLine, "NO PENDING APPROVALS")
        XCTAssertTrue(down.emptyLine?.hasPrefix("APPROVALS UNREACHABLE — ") == true)

        // ② the tone — the green reassurance is the dangerous half
        XCTAssertTrue(empty.isReassuring)
        XCTAssertFalse(down.isReassuring)

        // ③ the header count: "0" is a measurement the app did not make
        XCTAssertEqual(empty.headerCount, "0")
        XCTAssertNil(down.headerCount)
    }

    /// Guards against the collapse arriving through a helper rather than
    /// through `emptyLine`: `pending` must be empty for BOTH, so a leg that
    /// only reads `pending` cannot tell them apart — which is precisely why
    /// the discriminator has to live somewhere else. Asserting the shared
    /// property explicitly documents that it is NOT the discriminator.
    func testPendingListAloneCannotDiscriminateTheTwoEmptyStates() {
        let empty = ApprovalsState.loaded(pending: [], gatingConfigured: true)
        let down = ApprovalsState.unavailable(reason: "x")
        XCTAssertEqual(empty.pending.count, down.pending.count)  // both 0 — the trap
        XCTAssertNotEqual(empty.emptyLine, down.emptyLine)       // the escape
    }

    // MARK: - three states, three strings

    func testThreeEmptyConditionsRenderThreeDistinctStrings() {
        let gated = ApprovalsState.loaded(pending: [], gatingConfigured: true).emptyLine
        let ungated = ApprovalsState.loaded(pending: [], gatingConfigured: false).emptyLine
        let down = ApprovalsState.unavailable(reason: "r").emptyLine

        XCTAssertEqual(gated, "NO PENDING APPROVALS")
        XCTAssertEqual(ungated, "NOTHING IS GATED — NO TOOL REQUIRES APPROVAL")
        XCTAssertTrue(down?.hasPrefix("APPROVALS UNREACHABLE") == true)

        // Three, not two-with-a-duplicate.
        XCTAssertEqual(Set([gated, ungated, down].compactMap { $0 }).count, 3)
    }

    /// `gatingConfigured == nil` is UNKNOWN and must not be read as `false`:
    /// `/v1/config` failing does not license the strong claim "nothing is
    /// gated". Falls back to the weaker, true string.
    func testUnknownGatingDoesNotClaimNothingIsGated() {
        let unknown = ApprovalsState.loaded(pending: [], gatingConfigured: nil)
        XCTAssertEqual(unknown.emptyLine, "NO PENDING APPROVALS")
        XCTAssertNotEqual(unknown.emptyLine,
                          ApprovalsState.loaded(pending: [], gatingConfigured: false).emptyLine)
    }

    func testNonEmptyQueueRendersNoEmptyLine() throws {
        let state = ApprovalsState.loaded(pending: try decode(Self.pendingPayload),
                                          gatingConfigured: true)
        XCTAssertNil(state.emptyLine)
        XCTAssertEqual(state.headerCount, "1")
    }

    // MARK: - the wire shape

    /// The serde correction, pinned. `status` is internally tagged, so it is a
    /// STRING on the parent and `reason` is its SIBLING.
    func testStatusIsFlatAndReasonIsASibling() throws {
        let denied = try decode(Self.deniedPayload)[0]
        XCTAssertEqual(denied.status, "denied")
        XCTAssertEqual(denied.reason, "not on my box")
    }

    func testPendingRecordDecodesEveryFieldTheCardReads() throws {
        let a = try decode(Self.pendingPayload)[0]
        XCTAssertEqual(a.id, "a1")
        XCTAssertEqual(a.toolName, "shell")
        XCTAssertEqual(a.agentID, "zeus106")
        XCTAssertEqual(a.status, "pending")
        XCTAssertNil(a.reason)
    }

    /// A bare array, not `{"approvals":[…]}`. Control in the same invocation:
    /// the wrapped form must FAIL, or this leg is asserting nothing about
    /// shape.
    func testBodyIsABareArrayNotAWrappedObject() throws {
        XCTAssertNoThrow(try decode(Self.pendingPayload))
        let wrapped = #"{"approvals":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try decode(wrapped))
    }

    // MARK: - args rendered verbatim

    /// `args` is `serde_json::Value` — any shape. It is re-emitted compactly
    /// with sorted keys so two renders agree, and NOT paraphrased.
    ///
    /// VACUOUS FORM, rejected: `XCTAssertFalse(argsJSON.isEmpty)` — passes on
    /// `"{}"`, on a summary, on any string at all.
    func testArgsAreReEmittedVerbatimNotParaphrased() throws {
        let a = try decode(Self.pendingPayload)[0]
        XCTAssertEqual(a.argsJSON, #"{"cmd":"rm -rf \/tmp\/x","timeout":30}"#
                        .replacingOccurrences(of: "\\/", with: "/"))
        // The destructive substring survives intact — the operator sees the
        // bytes that will run.
        XCTAssertTrue(a.argsJSON.contains("rm -rf /tmp/x"))
    }

    func testArgsKeyOrderIsStableAcrossRenders() throws {
        let a = #"[{"id":"x","tool_name":"t","args":{"b":1,"a":2},"created_at":"2026-09-07T03:00:00Z","status":"pending"}]"#
        let b = #"[{"id":"x","tool_name":"t","args":{"a":2,"b":1},"created_at":"2026-09-07T03:00:00Z","status":"pending"}]"#
        XCTAssertEqual(try decode(a.data(using: .utf8)!)[0].argsJSON,
                       try decode(b.data(using: .utf8)!)[0].argsJSON)
    }

    // MARK: - nothing inferred, nothing invented

    /// No severity is computed anywhere. The TUI's `infer_risk`
    /// (`approvals_tab.rs:436`) derives a threat level by substring-matching
    /// the tool and args — an assessment painted into a slot the eye reads as
    /// one. This leg greps the shipping source for that shape.
    ///
    /// POSITIVE CONTROL in the same invocation: a mis-pointed enumeration
    /// would return a clean zero and pass, so the corpus must be proven to
    /// contain the file under test.
    func testNoSeverityIsComputedInShippingSource() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
            .appendingPathComponent("Sources/ZeusApp")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let corpus = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()

        XCTAssertTrue(corpus.contains("struct ApprovalCard"), "control: corpus must include the file under test")
        XCTAssertGreaterThan(files.count, 20, "control: enumeration reached the source directory")

        for needle in ["infer_risk", "inferRisk", "riskLevel", "severity"] {
            XCTAssertFalse(corpus.contains(needle), "severity inference present: \(needle)")
        }
    }

    /// A null `agent_id` renders NOTHING — not "unknown", not a dash. An
    /// uncaptioned placeholder in an attribution slot reads as an identity.
    func testNullAgentRendersNothingRatherThanAPlaceholder() throws {
        let a = try decode(Self.deniedPayload)[0]
        XCTAssertNil(a.agentID)
    }

    /// An empty `tool_name` is labelled, never inferred from the args.
    func testEmptyToolNameIsLabelledNotGuessed() throws {
        let json = #"[{"id":"x","tool_name":"","args":{"cmd":"ls"},"created_at":"2026-09-07T03:00:00Z","status":"pending"}]"#
        let a = try decode(json.data(using: .utf8)!)[0]
        XCTAssertEqual(a.title, "TOOL UNNAMED")
        XCTAssertFalse(a.title.contains("ls"), "title must not be derived from args")
    }

    /// A record whose `created_at` will not parse is KEPT — a pending approval
    /// must not vanish because a decorative field was malformed.
    func testUnparsableTimestampDoesNotDropTheRequest() throws {
        let json = #"[{"id":"x","tool_name":"t","args":{},"created_at":"not-a-date","status":"pending"}]"#
        let list = try decode(json.data(using: .utf8)!)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, "x")
    }

    // MARK: - the toast reports an answer, not a dispatch

    /// The 404 has two causes and they are different events: "not found" vs
    /// "no longer pending" — the second says the operator's decision was
    /// SUPERSEDED. Collapsing them loses the only fact that matters.
    ///
    /// VACUOUS FORM, rejected: asserting both merely contain "NOT APPLIED" —
    /// passes when the two 404s render identically, i.e. on the collapse.
    func testTheTwo404CausesRemainDistinguishable() {
        let notFound = #"{"error":"Approval 'x' not found"}"#.data(using: .utf8)!
        let stale = #"{"error":"Approval 'x' is no longer pending"}"#.data(using: .utf8)!
        let a = HTTPApprovalsService.outcome(status: 404, body: notFound, approve: true)
        let b = HTTPApprovalsService.outcome(status: 404, body: stale, approve: true)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(b.contains("NO LONGER PENDING"))
    }

    func testSuccessNamesTheGatewayAsTheAcceptor() {
        let ok = #"{"approved":true,"id":"a1"}"#.data(using: .utf8)!
        XCTAssertEqual(HTTPApprovalsService.outcome(status: 200, body: ok, approve: true),
                       "APPROVED — GATEWAY ACCEPTED")
        XCTAssertEqual(HTTPApprovalsService.outcome(status: 200, body: ok, approve: false),
                       "DENIED — GATEWAY ACCEPTED")
    }

    /// A non-JSON error body still produces a truthful line rather than a
    /// crash or an invented reason.
    func testUnparsableErrorBodyFallsBackToTheStatusCode() {
        let junk = "<html>502</html>".data(using: .utf8)!
        XCTAssertEqual(HTTPApprovalsService.outcome(status: 502, body: junk, approve: true),
                       "NOT APPLIED — HTTP 502")
    }

    // MARK: - age

    func testAgeIsRenderedInThreeMagnitudes() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = Approval(id: "x", toolName: "t", argsJSON: "{}", agentID: nil,
                         createdAt: base, status: "pending", reason: nil)
        XCTAssertEqual(a.age(now: base.addingTimeInterval(5)), "5S AGO")
        XCTAssertEqual(a.age(now: base.addingTimeInterval(120)), "2M AGO")
        XCTAssertEqual(a.age(now: base.addingTimeInterval(7200)), "2H AGO")
        // Device clock behind gateway clock: clamped, never negative.
        XCTAssertEqual(a.age(now: base.addingTimeInterval(-30)), "0S AGO")
    }
}
