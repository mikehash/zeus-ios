import XCTest
@testable import Zeus

final class ReplyLengthTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let name = "ReplyLengthTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    /// Records what reaches the seam; every other method is unreachable here.
    private final class Recorder: SessionCapabilities, @unchecked Sendable {
        var lengths: [ReplyLength] = []
        func setReplyLength(_ length: ReplyLength) throws { lengths.append(length) }
        func hasProvider() async throws -> Bool { false }
        func listModels(id: String, key: String, baseURL: String?) throws -> [String] { [] }
        func setProvider(id: String, model: String, key: String, baseURL: String?) throws {}
        func sessions() async throws -> [SessionRow] { [] }
        func messages(sessionID: String) async throws -> [TurnMessage] { [] }
        func remember(fact: String) async throws {}
        func indexSize() async throws -> UInt32? { nil }
        func search(query: String) async throws -> [RecallHit] { [] }
        func stageAttachment(fileName: String, bytes: Data) async throws -> String { "" }
    }

    func testFreshInstallIsNormal() {
        XCTAssertEqual(ReplyLengthPreference.current(defaults()), .normal)
    }

    func testRowCyclesAllThreeAndWraps() {
        XCTAssertEqual(ReplyLengthPreference.brief.next, .normal)
        XCTAssertEqual(ReplyLengthPreference.normal.next, .detailed)
        XCTAssertEqual(ReplyLengthPreference.detailed.next, .brief)
    }

    func testFfiMappingIsOneToOne() {
        XCTAssertEqual(ReplyLengthPreference.brief.ffi, .brief)
        XCTAssertEqual(ReplyLengthPreference.normal.ffi, .normal)
        XCTAssertEqual(ReplyLengthPreference.detailed.ffi, .detailed)
    }

    /// The stored preference reaches the core seam. Vacuity: the default
    /// delivers `.normal`, the stored one delivers `.brief` — they differ.
    func testTheStoredLengthReachesTheCore() {
        let d = defaults()
        let rec = Recorder()
        ReplyLengthPreference.apply(to: rec, d)
        ReplyLengthPreference.set(.brief, d)
        ReplyLengthPreference.apply(to: rec, d)
        XCTAssertEqual(rec.lengths, [.normal, .brief])
        XCTAssertNotEqual(rec.lengths.first, rec.lengths.last)
    }

    /// The arming act hands the length to the core BEFORE `CoreArming.arm`,
    /// so `set_provider`'s re-render carries it.
    func testTheArmingSiteAppliesTheLengthBeforeTheArm() throws {
        let src = try source("Sources/ZeusApp/RootView.swift")
        XCTAssertTrue(src.contains("static func armedResolution"), "POS control: file read")
        let apply = try XCTUnwrap(src.range(of: "ReplyLengthPreference.apply(to: core)"))
        let arm = try XCTUnwrap(src.range(of: "CoreArming.arm(commission: commissionForArming"))
        XCTAssertLessThan(apply.lowerBound, arm.lowerBound)
        XCTAssertEqual(src.components(separatedBy: "ReplyLengthPreference.apply(").count - 1, 1)
    }

    /// The Settings row re-arms — otherwise the choice waits for relaunch.
    func testTheSettingsRowRaisesTheReArm() throws {
        let settings = try source("Sources/ZeusApp/SettingsView.swift")
        let root = try source("Sources/ZeusApp/RootView.swift")
        XCTAssertTrue(settings.contains("ReplyLengthPreference.set(next)"), "POS control")
        XCTAssertTrue(settings.contains("onReplyLengthChanged()"))
        let wire = try XCTUnwrap(root.range(of: "onReplyLengthChanged: {"))
        XCTAssertTrue(root[wire.upperBound...].prefix(160).contains("RootView.armedResolution"))
    }

    /// The gateway refuses rather than reporting a setting it cannot enforce.
    func testTheGatewayRefuses() throws {
        let src = try source("Sources/ZeusApp/GatewayCapabilities.swift")
        XCTAssertTrue(src.contains("func setReplyLength"), "POS control")
        XCTAssertTrue(src.contains("GatewayError.unimplemented(method: \"setReplyLength\")"))
    }
}
