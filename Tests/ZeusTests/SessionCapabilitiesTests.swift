import XCTest
@testable import Zeus

/// S2's own legs. "All 544 still pass" is the refactor's headline instrument
/// and it is a WEAK one: it proves nothing was broken, not that the new seam
/// carries what it claims. These measure the forwarder itself.
///
/// The argument that motivates the whole file: the migration renamed
/// `baseUrl:` to `baseURL:` at four sites. A forwarder that dropped the
/// argument and passed `nil` instead would COMPILE, and every existing leg
/// would stay green — the arming legs assert on the returned reason string,
/// not on what reached the core. A dropped base URL is exactly how an Ollama
/// route silently repoints to a default host.
final class SessionCapabilitiesTests: XCTestCase {

    /// Records every argument it receives. Not a stub: the subject here is
    /// what ARRIVES, so a double that discarded its arguments would be unable
    /// to fail the test it exists for.
    private final class RecordingCore: ZeusCoreProtocol {
    func stageAttachment(fileName: String, bytes: Data) throws -> String {
        "attachments/stub-\(fileName)"
    }

        var armed = false
        var size: UInt32 = 0
        var modelRows: [String] = []
        var hits: [SearchHit] = []
        var turns: [TurnMessage] = []
        var infos: [SessionInfo] = []
        var facts: [String] = []

        private(set) var listCalls: [(id: String, key: String, baseUrl: String?)] = []
        private(set) var setCalls: [(id: String, model: String, key: String, baseUrl: String?)] = []
        private(set) var messageCalls: [String] = []

        func hasProvider() -> Bool { armed }
        func indexSize() -> UInt32 { size }

        func listModels(id: String, key: String, baseUrl: String?) throws -> [String] {
            listCalls.append((id, key, baseUrl))
            return modelRows
        }

        func setProvider(id: String, model: String, key: String, baseUrl: String?) throws {
            setCalls.append((id, model, key, baseUrl))
        }

        func messages(sessionId: String) throws -> [TurnMessage] {
            messageCalls.append(sessionId)
            return turns
        }

        func sessions() throws -> [SessionInfo] { infos }
        func remember(fact: String) throws { facts.append(fact) }
        func search(query: String) -> [SearchHit] { hits }
        func send(sessionId: String, text: String, images: [ImageAttachment], sink: TokenSink) throws {}
    }

    // MARK: - the arguments survive the seam

    /// THE BASE URL REACHES THE CORE ON BOTH CALLS THAT CARRY ONE.
    ///
    /// The `baseUrl:` → `baseURL:` rename is a label change at the seam, and a
    /// label change is the cheapest possible place to lose a value: the call
    /// still compiles with `nil`. Both `listModels` and `setProvider` carry
    /// one, and both are asserted, because the two forwarders are separate
    /// lines and a fix to one does not fix the other.
    func testTheBaseURLSurvivesTheSeamOnBothCallsThatCarryOne() throws {
        let core = RecordingCore()
        let caps = EmbeddedCapabilities(core: core)

        _ = try caps.listModels(id: "ollama", key: "k", baseURL: "http://box:11434")
        try caps.setProvider(id: "ollama", model: "m", key: "k", baseURL: "http://box:11434")

        XCTAssertEqual(core.listCalls.first?.baseUrl, "http://box:11434",
                       "listModels dropped the base URL at the seam")
        XCTAssertEqual(core.setCalls.first?.baseUrl, "http://box:11434",
                       "setProvider dropped the base URL at the seam")
    }

    /// A `nil` BASE URL AND A PRESENT ONE ARRIVE DIFFERENTLY.
    ///
    /// The vacuity guard for the leg above. If the forwarder hardcoded `nil`,
    /// the previous test fails — but if it hardcoded a STRING, the previous
    /// test passes and this one fails. Together they pin the value, not the
    /// presence of a value.
    func testAnAbsentBaseURLIsNotTheSameAsAPresentOne() throws {
        let core = RecordingCore()
        let caps = EmbeddedCapabilities(core: core)

        _ = try caps.listModels(id: "anthropic", key: "k", baseURL: nil)
        _ = try caps.listModels(id: "ollama", key: "k", baseURL: "http://box:11434")

        XCTAssertNotEqual(core.listCalls[0].baseUrl, core.listCalls[1].baseUrl,
                          "both calls arrived with the same base URL — the " +
                          "argument is not being read")
        XCTAssertNil(core.listCalls[0].baseUrl)
    }

    /// THE SESSION ID SURVIVES ITS OWN RENAME.
    ///
    /// `messages(sessionId:)` → `messages(sessionID:)` is the second label
    /// change in the migration, and unlike the base URL it has no `nil` to
    /// hide behind — but a forwarder passing a constant would still compile.
    func testTheSessionIDSurvivesTheSeam() async throws {
        let core = RecordingCore()
        let caps = EmbeddedCapabilities(core: core)

        _ = try await caps.messages(sessionID: "session-a")
        _ = try await caps.messages(sessionID: "session-b")

        XCTAssertEqual(core.messageCalls, ["session-a", "session-b"])
    }

    // MARK: - the widened return

    /// A CORE'S INDEX SIZE IS NOT FOLDED INTO ABSENCE.
    ///
    /// The protocol widens `UInt32` to `UInt32?` so the gateway conformer can
    /// say "I could not read it". The embedded conformer must never USE that
    /// widening: it has a core, so every answer it gives is a reading. Zero is
    /// a reading. `NodesView.mnemosyneValue:206` renders `nil` as `NO CORE`
    /// and zero as `INDEX EMPTY`, and an embedded core reporting `NO CORE`
    /// would be a lie about the one fact that row exists to carry.
    func testAnEmbeddedZeroIsAReadingAndNotAnAbsence() async throws {
        let core = RecordingCore()
        core.size = 0
        let cap = EmbeddedCapabilities(core: core)
        let zero = try await cap.indexSize()
        XCTAssertEqual(zero, 0,
                       "an embedded core that answered zero must not surface " +
                       "as nil — NO CORE and INDEX EMPTY are different facts")

        core.size = 7
        let seven = try await EmbeddedCapabilities(core: core).indexSize()
        XCTAssertEqual(seven, 7)
    }

    /// A THROW CARRIES THE CORE'S OWN SENTENCE THROUGH THE SEAM.
    ///
    /// `RootView.remember:556` renders `"\(error)"` verbatim, and the bridge's
    /// errors name their cause. A forwarder that caught and rewrapped would
    /// discard the one string that says why — the defect that comment names,
    /// re-introduced one layer up.
    func testTheCoresOwnErrorReachesTheCaller() async throws {
        struct Named: Error, CustomStringConvertible { var description: String { "NO WORKSPACE AT /tmp/x" } }
        final class Throwing: ZeusCoreProtocol {
    func stageAttachment(fileName: String, bytes: Data) throws -> String {
        "attachments/stub-\(fileName)"
    }

            func messages(sessionId: String) throws -> [TurnMessage] { throw Named() }
            func hasProvider() -> Bool { false }
            func indexSize() -> UInt32 { 0 }
            func listModels(id: String, key: String, baseUrl: String?) throws -> [String] { [] }
            func setProvider(id: String, model: String, key: String, baseUrl: String?) throws {}
            func sessions() throws -> [SessionInfo] { [] }
            func remember(fact: String) throws {}
            func search(query: String) -> [SearchHit] { [] }
            func send(sessionId: String, text: String, images: [ImageAttachment], sink: TokenSink) throws {}
        }
        let caps = EmbeddedCapabilities(core: Throwing())
        do {
            _ = try await caps.messages(sessionID: "s")
            XCTFail("the throw did not reach the caller")
        } catch {
            XCTAssertEqual("\(error)", "NO WORKSPACE AT /tmp/x",
                           "the seam rewrapped the core's error and the cause " +
                           "was lost")
        }
    }

    // MARK: - the census this refactor exists to satisfy

    /// NO PRODUCTION VIEW HOLDS A `ZeusCoreProtocol` ANY MORE.
    ///
    /// The refactor's actual subject, and the only leg that measures it. The
    /// five sites named in the design doc — `ProviderArming:40,110,167`,
    /// `NodesView:125`, `HistoryView:24` — are the parity gap; a later commit
    /// re-introducing one would restore it silently, because a view holding a
    /// core compiles perfectly and simply does nothing on a remote gateway.
    ///
    /// `EmbeddedTransport` and `SessionCapabilities` are the two files allowed
    /// to name the type: one is the prose seam's embedded conformer, the other
    /// is this seam's. Both are the boundary itself.
    func testNoViewHoldsACoreDirectly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ZeusApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(names.count, 20,
                            "the source scan found almost nothing — the path " +
                            "is wrong and this census is measuring an empty set")

        let allowed: Set<String> = ["EmbeddedTransport.swift", "SessionCapabilities.swift"]
        var offenders: [String] = []
        for name in names where !allowed.contains(name) {
            let body = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            let code = body.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains(": ZeusCoreProtocol") { offenders.append(name) }
        }
        XCTAssertEqual(offenders, [], "these files hold a core directly and " +
                       "will not work against a remote gateway")

        // POS: the needle finds the type where it IS legitimately named, so an
        // empty offender list is a statement about the tree and not about a
        // needle that matches nothing.
        let conformer = try String(contentsOf: root.appendingPathComponent("SessionCapabilities.swift"),
                                   encoding: .utf8)
        XCTAssertTrue(conformer.contains(": ZeusCoreProtocol"),
                      "POS control failed — the needle matches nothing, so " +
                      "the zero above is meaningless")
    }

    // MARK: - S3a: the embedded mapping into the app-owned row

    /// THE EMBEDDED CONFORMER MUST NOT LOSE THE KEY IT HAS.
    ///
    /// The seam now returns `[SessionRow]` with an Optional key, and the
    /// gateway conformer returns `nil` for every row. A mapping that dropped
    /// the embedded key would compile, would satisfy the type, and would turn
    /// the LOCAL history into server order — reading as "the list is fine" on
    /// the one path that has a real answer.
    func testTheEmbeddedConformerCarriesTheKeyIntoTheRow() async throws {
        let core = RecordingCore()
        core.infos = [SessionInfo(id: "s1", updatedAtRfc3339: "2026-09-11T04:00:00Z"),
                      SessionInfo(id: "s2", updatedAtRfc3339: "2026-09-11T05:00:00Z")]
        let rows = try await EmbeddedCapabilities(core: core).sessions()

        XCTAssertEqual(rows.map(\.id), ["s1", "s2"])
        XCTAssertEqual(rows.compactMap(\.sortKey),
                       ["2026-09-11T04:00:00Z", "2026-09-11T05:00:00Z"])
        // The vacuity assertion, and the whole point: the embedded path must
        // NOT look like the gateway path.
        XCTAssertFalse(History.isServerOrder(rows),
                       "an embedded list has real keys and this screen sorts it")
    }
}
