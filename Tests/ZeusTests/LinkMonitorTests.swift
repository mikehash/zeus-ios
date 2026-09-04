import XCTest
@testable import Zeus

/// Guards the one defect in the ship-layer list that shipped a LIE rather than
/// a gap: `RootView:90`'s `statusLine: "LINKED · KITCHEN NODE"` and
/// `NodesView:34`'s `@State private var nodeOnline = true`. Both rendered
/// LINKED with no gateway configured, none reachable, and none answering.
///
/// Every leg below is a claim about the mapping from a PROBE RESULT to what
/// the user reads. No network, no sleep, no server.
@MainActor
final class LinkMonitorTests: XCTestCase {

    // MARK: - Probe doubles

    /// Answers with a scripted verdict and counts its calls.
    ///
    /// `@unchecked Sendable`: `LinkProbe` refines `Sendable`
    /// (`LinkMonitor.swift`, same reason as `SessionTransport:17`), so a
    /// conformer holding a mutable recorder must say so. Guarded by the lock
    /// rather than by the fact that these tests happen to be `@MainActor` —
    /// the compiler checks the CONFORMANCE, not the call sites.
    final class ScriptedProbe: LinkProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private let verdict: LinkState

        init(_ verdict: LinkState) { self.verdict = verdict }

        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

        func probe(_ endpoint: GatewayConfig.Endpoint) async -> LinkState {
            lock.lock(); _calls += 1; lock.unlock()
            return verdict
        }
    }

    private func endpoint(_ raw: String = "http://192.168.1.100:8080") -> GatewayConfig {
        .resolved(.init(url: URL(string: raw)!, token: nil))
    }

    // MARK: - The fabrication guard

    /// THE LEG THIS FILE EXISTS FOR. Under every state that is not a measured
    /// 2xx, no surface may read LINKED.
    ///
    /// Exhaustive by construction over the four cases: `LinkState` is an enum,
    /// so a fifth arm makes the switch in `isLinked` fail to compile and this
    /// leg's list becomes visibly short.
    func testOnlyAMeasured2xxEverReadsLinked() {
        let notLinked: [LinkState] = [
            .unconfigured,
            .probing,
            .unreachable(host: "h", reason: "timeout"),
            .unreachable(host: "h", reason: "http 502"),
        ]
        // Vacuity floor: the list is non-empty and the POSITIVE case really
        // does produce the string, so a `badgeText` that returned "" for
        // everything could not pass this leg.
        XCTAssertEqual(notLinked.count, 4)
        XCTAssertEqual(LinkState.linked(host: "h", ms: 4).badgeText, "LINKED")
        XCTAssertTrue(LinkState.linked(host: "h", ms: 4).isLinked)

        for state in notLinked {
            XCTAssertFalse(state.isLinked, "\(state) claimed a link")
            XCTAssertNotEqual(state.badgeText, "LINKED", "\(state) badge read LINKED")
            XCTAssertFalse(state.statusLine.hasPrefix("LINKED"),
                           "\(state) status line read LINKED: \(state.statusLine)")
        }
    }

    /// The old literal is gone from the tree, not merely unused. A string that
    /// still exists can be re-wired by a later edit that looks like a revert.
    func testTheHardcodedStatusLineIsNotProducibleByAnyState() {
        for state in [LinkState.unconfigured,
                      .probing,
                      .linked(host: "kitchen", ms: 3),
                      .unreachable(host: "kitchen", reason: "refused")] {
            XCTAssertNotEqual(state.statusLine, "LINKED · KITCHEN NODE")
        }
    }

    // MARK: - Initial state

    /// An unconfigured build must NOT show `LINKING…` — a state it could never
    /// leave, since `start()` returns immediately with no endpoint.
    func testUnconfiguredStartsUnconfiguredNotProbing() {
        for config in [GatewayConfig.absent,
                       .malformed(raw: "ftp://x", reason: .unsupportedScheme)] {
            let monitor = LinkMonitor(config: config,
                                      probe: ScriptedProbe(.linked(host: "h", ms: 1)))
            XCTAssertEqual(monitor.state, .unconfigured)
        }
    }

    func testResolvedStartsProbing() {
        let monitor = LinkMonitor(config: endpoint(),
                                  probe: ScriptedProbe(.linked(host: "h", ms: 1)))
        XCTAssertEqual(monitor.state, .probing)
    }

    /// An unconfigured monitor must never call the probe. Otherwise a build
    /// with no gateway fires a request every interval at a URL it does not
    /// have.
    func testUnconfiguredNeverProbes() async {
        let probe = ScriptedProbe(.linked(host: "h", ms: 1))
        let monitor = LinkMonitor(config: .absent, probe: probe)
        await monitor.probeOnce()
        XCTAssertEqual(probe.calls, 0)
        XCTAssertEqual(monitor.state, .unconfigured)
    }

    // MARK: - Verdict publication

    func testProbeVerdictReachesTheState() async {
        let probe = ScriptedProbe(.unreachable(host: "192.168.1.100", reason: "refused"))
        let monitor = LinkMonitor(config: endpoint(), probe: probe)
        await monitor.probeOnce()

        XCTAssertEqual(probe.calls, 1)                 // vacuity floor
        XCTAssertFalse(monitor.state.isLinked)
        XCTAssertEqual(monitor.state.badgeText, "REMOTE")
        XCTAssertTrue(monitor.state.statusLine.contains("REFUSED"))
    }

    func testLinkedVerdictCarriesHostAndLatency() async {
        let monitor = LinkMonitor(config: endpoint(),
                                  probe: ScriptedProbe(.linked(host: "192.168.1.100", ms: 7)))
        await monitor.probeOnce()

        XCTAssertTrue(monitor.state.isLinked)
        XCTAssertEqual(monitor.state.statusLine, "LINKED · 192.168.1.100 · 7MS")
    }

    /// `start()` twice must not stack two loops. Two loops halve the effective
    /// interval and nothing in the UI would show it.
    func testStartIsIdempotent() async throws {
        let probe = ScriptedProbe(.linked(host: "h", ms: 1))
        let monitor = LinkMonitor(config: endpoint(), probe: probe,
                                  interval: .milliseconds(40))
        monitor.start()
        monitor.start()
        monitor.start()
        try await Task.sleep(for: .milliseconds(100))
        monitor.stop()
        let n = probe.calls
        // Three stacked loops at 40ms over 100ms would be ~9; one loop is 2-3.
        // Asserting the UPPER bound only: the lower bound is a timing claim
        // about the scheduler and would flake on a loaded box.
        XCTAssertGreaterThanOrEqual(n, 1, "the loop never ran — leg is vacuous")
        XCTAssertLessThanOrEqual(n, 5, "start() stacked loops: \(n) probes")
    }

    func testStopHaltsPolling() async throws {
        let probe = ScriptedProbe(.linked(host: "h", ms: 1))
        let monitor = LinkMonitor(config: endpoint(), probe: probe,
                                  interval: .milliseconds(20))
        monitor.start()
        try await Task.sleep(for: .milliseconds(60))
        monitor.stop()
        let atStop = probe.calls
        XCTAssertGreaterThanOrEqual(atStop, 1, "never polled — leg is vacuous")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.calls, atStop, "polling continued after stop()")
    }

    // MARK: - The probe's own URL and error mapping

    /// `/health` and not `/v1/health`. Verified against `~/Zeus`
    /// `crates/zeus-api/src/public_paths.rs:33`, which lists `"/health"` in
    /// `PUBLIC_EXACT` — so this probe needs no credential.
    func testHealthURLIsAppendedToTheBase() {
        let base = URL(string: "http://192.168.1.100:8080")!
        XCTAssertEqual(HTTPLinkProbe.healthURL(base: base).absoluteString,
                       "http://192.168.1.100:8080/health")
    }

    func testErrorsMapToPhrasesNotSentences() {
        XCTAssertEqual(HTTPLinkProbe.shortReason(URLError(.timedOut)), "timeout")
        XCTAssertEqual(HTTPLinkProbe.shortReason(URLError(.cannotConnectToHost)), "refused")
        XCTAssertEqual(HTTPLinkProbe.shortReason(URLError(.notConnectedToInternet)), "offline")
        // Anything unrecognised must still be a phrase, never a sentence with
        // a period that would run past the pill.
        let fallback = HTTPLinkProbe.shortReason(URLError(.badURL))
        XCTAssertEqual(fallback, "unreachable")
        XCTAssertFalse(fallback.contains("."))
    }

    // MARK: - Background behaviour

    /// The suspend invariant: **a verdict may not outlive the app's ability to
    /// re-take it.**
    ///
    /// iOS keeps the last rendered frame for the app switcher and for the
    /// instant before the first foreground frame draws, so a monitor that only
    /// stopped polling would show `LINKED · 12MS` after an arbitrarily long
    /// suspend — a measurement with nothing behind it, which is the `t-12min`
    /// defect exactly.
    func testSuspendInvalidatesTheVerdictNotJustThePolling() async {
        let probe = ScriptedProbe(.linked(host: "192.168.1.100", ms: 12))
        let monitor = LinkMonitor(config: endpoint(), probe: probe, interval: .seconds(60))

        await monitor.probeOnce()
        // VACUITY FLOOR: without a real LINKED verdict first, the assertion
        // below passes over a monitor that was never linked at all.
        XCTAssertTrue(monitor.state.isLinked, "never became linked — leg is vacuous")

        monitor.suspend()

        XCTAssertFalse(monitor.state.isLinked,
                       "a LINKED verdict survived backgrounding")
        XCTAssertEqual(monitor.state, .probing)
        XCTAssertEqual(monitor.state.badgeText, "LINKING")
    }

    /// Suspend must also stop the loop. Invalidating without stopping would
    /// leave a `Task.sleep` cycle scheduled in a process the OS is about to
    /// freeze and eventually kill.
    func testSuspendStopsPolling() async throws {
        let probe = ScriptedProbe(.linked(host: "h", ms: 3))
        let monitor = LinkMonitor(config: endpoint(), probe: probe, interval: .milliseconds(20))

        monitor.start()
        try await Task.sleep(for: .milliseconds(60))
        let atSuspend = probe.calls
        XCTAssertGreaterThanOrEqual(atSuspend, 1, "never polled — leg is vacuous")

        monitor.suspend()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.calls, atSuspend, "polling continued after suspend()")
    }

    /// Unconfigured is exempt: it is not a measurement, it is the absence of a
    /// target. Downgrading it to `.probing` would tell the operator the app is
    /// looking for a gateway it has no address for.
    func testSuspendLeavesUnconfiguredAlone() {
        let monitor = LinkMonitor(config: .absent, probe: ScriptedProbe(.probing))
        XCTAssertEqual(monitor.state, .unconfigured)

        monitor.suspend()

        XCTAssertEqual(monitor.state, .unconfigured,
                       "an unconfigured gateway was reported as LINKING")
    }

    /// Resume re-establishes a live verdict, so the `.probing` window that
    /// `suspend` opens is bounded by the first foreground probe.
    func testResumeProbesAndPublishesAFreshVerdict() async throws {
        let probe = ScriptedProbe(.linked(host: "192.168.1.100", ms: 7))
        let monitor = LinkMonitor(config: endpoint(), probe: probe, interval: .seconds(60))

        monitor.suspend()
        XCTAssertFalse(monitor.state.isLinked, "not suspended — leg is vacuous")

        monitor.resume()
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertTrue(monitor.state.isLinked, "resume did not re-measure")
        XCTAssertEqual(monitor.state, .linked(host: "192.168.1.100", ms: 7))
    }

    /// Resume after suspend must not stack loops. `suspend` clears the task
    /// handle, so a resume that re-entered without clearing would double the
    /// poll rate invisibly — the same defect `start()`'s idempotence guards.
    func testSuspendResumeDoesNotStackTwoPollLoops() async throws {
        let probe = ScriptedProbe(.linked(host: "h", ms: 1))
        let monitor = LinkMonitor(config: endpoint(), probe: probe, interval: .milliseconds(40))

        monitor.start()
        monitor.suspend()
        monitor.resume()
        monitor.resume()          // second resume must be a no-op
        try await Task.sleep(for: .milliseconds(130))
        monitor.stop()

        // One loop at 40ms over ~130ms is 3-4 probes; two stacked loops would
        // be 6-8. The bound is generous on the low side and still separates
        // the two worlds.
        XCTAssertGreaterThanOrEqual(probe.calls, 2, "never polled — leg is vacuous")
        XCTAssertLessThanOrEqual(probe.calls, 5, "two poll loops are running")
    }
}
