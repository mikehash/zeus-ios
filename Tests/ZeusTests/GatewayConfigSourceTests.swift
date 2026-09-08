import XCTest
@testable import Zeus

/// c2 — the four byte-sending surfaces follow a saved URL WITHIN the session.
///
/// Every leg here exists because a weaker one passes on the defect:
///
///   * a leg on `state` alone passes on a stale-but-reachable old host — the
///     pill says LINKED because the LAUNCH host answered, and the operator
///     has no way to tell.
///   * a leg on "did the store change" passes on a config nothing reads.
///   * a storage census (`private let config` == 0) proves the freeze left
///     the STORAGE and says nothing about a freeze at init or inside a
///     running task — the two places it actually lived.
///
/// So the discriminating instrument is the ENDPOINT A COLLABORATOR WAS
/// HANDED, recorded, after the change.
@MainActor
final class GatewayConfigSourceTests: XCTestCase {

    // MARK: - instruments

    /// Records every endpoint it is probed with, in order.
    final class RecordingProbe: LinkProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var _hosts: [String] = []
        private let verdict: LinkState
        init(_ verdict: LinkState = .linked(host: "h", ms: 1)) { self.verdict = verdict }
        var hosts: [String] { lock.lock(); defer { lock.unlock() }; return _hosts }
        func probe(_ endpoint: GatewayConfig.Endpoint) async -> LinkState {
            lock.lock(); _hosts.append(endpoint.url.absoluteString); lock.unlock()
            return verdict
        }
    }

    struct RecordingFetcher: RouteCatalogFetching {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _hosts: [String] = []
            var hosts: [String] { lock.lock(); defer { lock.unlock() }; return _hosts }
            func note(_ s: String) { lock.lock(); _hosts.append(s); lock.unlock() }
        }
        let box: Box
        func fetch(_ endpoint: GatewayConfig.Endpoint,
                   credentials: CredentialProviding) async -> RouteCatalogState {
            box.note(endpoint.url.absoluteString)
            return .loaded(routes: [], activeModel: nil)
        }
    }

    private static let old = GatewayConfig.resolved(
        .init(url: URL(string: "http://old.example:8080")!, token: nil))
    private static let new = GatewayConfig.resolved(
        .init(url: URL(string: "http://new.example:9090")!, token: nil))

    private func resolution(_ c: GatewayConfig) -> GatewayConfig.Resolution {
        .init(config: c, source: .commission)
    }

    // MARK: - the sole writer

    /// `adopt` is the ONE assignment site. A settable property would have as
    /// many writers as it has holders, and "which surface last wrote the
    /// config" is not a question this app can answer at runtime.
    func testAdoptIsTheOnlyPathThatChangesTheCurrentConfig() {
        let source = GatewayConfigSource(resolution(Self.old))
        XCTAssertEqual(source.config, Self.old)
        source.adopt(resolution(Self.new))
        XCTAssertEqual(source.config, Self.new)
        // NOT VACUOUS: the two configs must actually differ, or a source that
        // ignored `adopt` entirely would satisfy the assertion above.
        XCTAssertNotEqual(Self.old, Self.new)
    }

    // MARK: - THE PROBE LEG (the restart discriminator)

    /// 🔴 THE LEG c2 EXISTS FOR. `LinkMonitor.start()` binds its endpoint ONCE
    /// into the poll task and is idempotent, so a monitor that merely READS a
    /// shared source keeps probing the launch host forever — with a pill that
    /// reads LINKED, because the old host is usually still up.
    ///
    /// Asserting on `state` cannot see that. This asserts on the endpoints the
    /// probe was HANDED.
    func testAdoptingANewURLMovesTheProbeToTheNewHost() async {
        let probe = RecordingProbe()
        let source = GatewayConfigSource(resolution(Self.old))
        let monitor = LinkMonitor(source: source, probe: probe, interval: .milliseconds(20))
        monitor.start()

        try? await Task.sleep(for: .milliseconds(60))
        // POS: the walk is live — the old host WAS probed. Without this, an
        // empty `hosts` array satisfies "no old host" and greens on a monitor
        // that never ran at all.
        XCTAssertTrue(probe.hosts.contains("http://old.example:8080"),
                      "VOID: the probe never ran, so the leg below measures nothing")

        source.adopt(resolution(Self.new))
        try? await Task.sleep(for: .milliseconds(80))
        await monitor.stop()

        guard let last = probe.hosts.last else {
            return XCTFail("VOID: no probe recorded")
        }
        XCTAssertEqual(last, "http://new.example:9090",
                       "the probe must follow the saved URL; a poll bound to the launch endpoint keeps reporting on a host the operator abandoned")
    }

    /// The label follows too — and separately, so a build that moved the label
    /// and not the probe fails the leg above rather than passing this one.
    func testAdoptingANewURLReDerivesTheLabel() async {
        let source = GatewayConfigSource(resolution(.absent))
        let monitor = LinkMonitor(source: source, probe: RecordingProbe(), interval: .seconds(60))
        XCTAssertEqual(monitor.state, .unconfigured)
        source.adopt(resolution(Self.new))
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(monitor.state, .probing,
                       "an unconfigured launch that adopts a URL must leave NO GATEWAY")
    }

    /// A monitor that was never started must not START because a URL was
    /// saved. `wantsPolling` is the operator's intent, distinct from whether
    /// a task happens to be alive.
    func testAdoptDoesNotOpenAPollTheOwnerNeverAskedFor() async {
        let probe = RecordingProbe()
        let source = GatewayConfigSource(resolution(Self.old))
        let monitor = LinkMonitor(source: source, probe: probe, interval: .milliseconds(20))
        source.adopt(resolution(Self.new))
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(probe.hosts.count, 0,
                       "a monitor nobody started must not begin polling on a config change")
        // NOT VACUOUS: it polls when it IS started.
        monitor.start()
        try? await Task.sleep(for: .milliseconds(40))
        await monitor.stop()
        XCTAssertGreaterThan(probe.hosts.count, 0)
    }

    // MARK: - the catalogue

    /// The route catalogue re-fetches against the new host. Same instrument:
    /// the endpoint the fetcher was handed, not the state it produced.
    func testAdoptingANewURLRefetchesTheCatalogueFromTheNewHost() async {
        let box = RecordingFetcher.Box()
        let source = GatewayConfigSource(resolution(Self.old))
        let store = RouteCatalogStore(source: source,
                                      fetcher: RecordingFetcher(box: box),
                                      credentials: StubCredentialProvider())
        await store.load()
        XCTAssertEqual(box.hosts, ["http://old.example:8080"],
                       "VOID: the first fetch never happened")

        source.adopt(resolution(Self.new))
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(box.hosts.last, "http://new.example:9090",
                       "the catalogue must be re-read from the host the operator just saved")
    }

    /// The approvals queue's LABEL re-derives. Its request path already read
    /// config per call, so the freeze there was the init-derived `state`.
    func testAdoptingANewURLReDerivesTheApprovalsLabel() async {
        let source = GatewayConfigSource(resolution(.absent))
        let store = ApprovalsStore(source: source, credentials: StubCredentialProvider())
        guard case .unconfigured = store.state else {
            return XCTFail("VOID: expected the unconfigured arm at launch")
        }
        source.adopt(resolution(Self.new))
        try? await Task.sleep(for: .milliseconds(40))
        if case .unconfigured = store.state {
            XCTFail("the queue must leave NO GATEWAY once a URL is live")
        }
    }

    // MARK: - the census (necessary, NOT sufficient — see the file header)

    /// No surface may re-freeze the config into its own storage. This is the
    /// STORAGE half; the probe leg above is the behaviour half, and the two
    /// are asserted separately because the census greens on a build that
    /// reads per use and never observes.
    func testNoSurfaceStoresItsOwnFrozenConfig() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ZeusApp")
        var frozen: [String] = []
        var walked = 0
        for name in ["LinkMonitor.swift", "Approvals.swift", "Route.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            walked += 1
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                if t.contains("let config: GatewayConfig") { frozen.append("\(name): \(t)") }
            }
        }
        XCTAssertEqual(walked, 3, "VOID: a source file did not open")
        XCTAssertEqual(frozen, [],
                       "a stored GatewayConfig is the launch-host freeze; take GatewayConfigSource instead")
    }

    /// `GatewayConfigSource.fixed` is a TEST seam. A production surface built
    /// on a fixed source is a re-freeze wearing a factory's name.
    func testTheFixedSourceHasNoProductionCallSite() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ZeusApp")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 20, "VOID: the Sources walk found almost nothing")
        var hits: [String] = []
        var declarations = 0
        for f in files {
            let text = try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                if t.contains("static func fixed(") { declarations += 1; continue }
                if t.contains(".fixed(") || t.contains("GatewayConfigSource.fixed") {
                    hits.append("\(f): \(t)")
                }
            }
        }
        XCTAssertEqual(declarations, 1, "VOID: the declaration walk missed its subject")
        XCTAssertEqual(hits, [], "the fixed source is a test seam and must not reach production")
    }

    /// The retired caption. `APPLIES ON NEXT LAUNCH` was TRUE at c1 and became
    /// a lie the moment the four surfaces started following a saved URL — its
    /// own docstring promised this leg would invert, so here it is inverted.
    func testTheNextLaunchCaptionIsRetired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ZeusApp")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
        var stale: [String] = []
        var liveNow = 0
        for f in files {
            let text = try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                if t.contains("APPLIES ON NEXT LAUNCH") { stale.append("\(f): \(t)") }
                if t.contains("LIVE NOW") { liveNow += 1 }
            }
        }
        XCTAssertEqual(stale, [], "the engine follows a saved URL now; this caption is a lie")
        XCTAssertGreaterThan(liveNow, 0, "VOID: the replacement string is not on the tree either")
    }

    /// SAVE re-resolves. The census is on the CALL SITE because a `View`
    /// initialiser is not callable from this target — sixth instance of the
    /// value-asserted / call-site-unguarded shape, recorded at `RootView`.
    func testSaveReResolvesThroughTheSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ZeusApp")
        let rootView = try String(contentsOf: root.appendingPathComponent("RootView.swift"), encoding: .utf8)
        let editor = try String(contentsOf: root.appendingPathComponent("GatewayEditor.swift"), encoding: .utf8)
        func code(_ s: String) -> [String] {
            s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
        }
        let adopts = code(rootView).filter { $0.contains("configSource.adopt(") }
        XCTAssertEqual(adopts.count, 1, "exactly ONE assignment site: the re-resolve after SAVE")
        XCTAssertTrue(adopts[0].contains("RootView.resolve(store: store)"),
                      "the re-resolve must read the store this view was handed, not a fresh one")
        XCTAssertEqual(code(editor).filter { $0.contains("onSaved()") }.count, 1,
                       "the editor must call back exactly once, after the write")
        XCTAssertEqual(code(rootView).filter { $0.contains("onSaved:") }.count, 1,
                       "VOID: the editor is not handed a re-resolve at all")
    }
}
