import XCTest
@testable import Zeus

/// Arc A — two controls that NARRATED AN ACT THAT NEVER HAPPENS, repaired.
///
/// 1. `LinkCard`'s re-probe arrow. On `.local` — every phone in the field —
///    `probeOnce` fell through a `guard case .resolved` whose `else` wrote
///    `.unconfigured`, turning a TRUE `LOCAL · ON THIS PHONE` into a FALSE
///    `NO GATEWAY · SET ZEUS_GATEWAY_URL`. Nothing restored it: `start()`
///    guards on `.resolved`, so no poll loop exists on that arm to re-derive
///    the label. It survived until relaunch, across four surfaces.
/// 2. `NodesView`'s ENROLL NODE. Toasted `SCAN THE NEW DEVICE` and began
///    nothing — a fabricated instruction, not merely a dead button.
///
/// APERTURE, STATED. `HomeView`/`NodesView` bodies cannot be rendered and read
/// back from this target, so the shape is the house one: the behavioural half
/// proves the MODEL over its whole domain, and a SOURCE CENSUS proves the view
/// wires it. Neither half alone is the claim — a behavioural leg stays green
/// with the body still passing an unconditional closure, which is precisely
/// the defect being repaired.
@MainActor
final class HonestControlsTests: XCTestCase {

    // MARK: - Probe double

    /// Counts calls and answers with a scripted verdict, so "did the probe
    /// run at all" is a measurement rather than an inference from state.
    final class CountingProbe: LinkProbe, @unchecked Sendable {
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

    // MARK: - the corruption, directly

    /// THE DEFECT LEG. A retry on `.local` must leave the embedded verdict
    /// exactly where it was.
    ///
    /// Written as a before/after equality on the FULL state plus an explicit
    /// `assertNotEqual` against the corrupt value, because `== .embedded`
    /// alone would also pass if `.embedded` and `.unconfigured` were ever
    /// collapsed into one case.
    func testARetryOnTheLocalArmDoesNotCorruptTheEmbeddedVerdict() async {
        let probe = CountingProbe(.linked(host: "h", ms: 1))
        let monitor = LinkMonitor(source: .fixed(.local(.ready)), probe: probe)

        XCTAssertEqual(monitor.state, .embedded, "vacuity floor: the arm did not start embedded")

        await monitor.probeOnce()

        XCTAssertEqual(monitor.state, .embedded,
                       "a retry moved the pill off the terminal embedded arm")
        XCTAssertNotEqual(monitor.state, .unconfigured,
                          "the shipped corruption is back: LOCAL became NO GATEWAY")
        XCTAssertEqual(monitor.state.statusLine, "LOCAL · ON THIS PHONE")
    }

    /// The three `.local` sub-arms are one arm for this purpose. `.checking`
    /// and `.noProvider` are just as un-probeable as `.ready`, and a repair
    /// that only covered the one the fixture happened to use would leave the
    /// corruption live for an operator who never picked a provider.
    func testEveryLocalSubArmIsTerminalUnderRetry() async {
        for arm in [GatewayConfig.local(.ready),
                    GatewayConfig.local(.noProvider),
                    GatewayConfig.local(.checking)] {
            let probe = CountingProbe(.linked(host: "h", ms: 1))
            let monitor = LinkMonitor(source: .fixed(arm), probe: probe)
            await monitor.probeOnce()
            XCTAssertEqual(monitor.state, .embedded, "\(arm) moved off embedded under retry")
            XCTAssertEqual(probe.calls, 0, "\(arm) sent a request with no endpoint to send it to")
        }
    }

    /// The neighbouring arms must be UNCHANGED by the repair. `.absent` and
    /// `.malformed` genuinely are unconfigured, and a switch that returned
    /// early for all three would silently retire a correct behaviour.
    func testTheUnconfiguredArmsStillPublishUnconfigured() async {
        for arm in [GatewayConfig.absent,
                    GatewayConfig.malformed(raw: "wat", reason: .notAURL)] {
            let probe = CountingProbe(.linked(host: "h", ms: 1))
            let monitor = LinkMonitor(source: .fixed(arm), probe: probe)
            await monitor.probeOnce()
            XCTAssertEqual(monitor.state, .unconfigured, "\(arm) stopped reporting unconfigured")
            XCTAssertEqual(probe.calls, 0)
        }
    }

    /// And the arm that DOES probe still does. Without this the whole repair
    /// could be "return early always" and every leg above stays green.
    func testTheResolvedArmStillProbesAndPublishes() async {
        let probe = CountingProbe(.linked(host: "kitchen", ms: 7))
        let monitor = LinkMonitor(source: .fixed(endpoint()), probe: probe)
        await monitor.probeOnce()
        XCTAssertEqual(probe.calls, 1, "the resolved arm stopped probing")
        XCTAssertEqual(monitor.state, .linked(host: "kitchen", ms: 7))
    }

    // MARK: - the predicate the view branches on

    /// `isProbeable` must partition by WHETHER THERE IS AN ENDPOINT, not by
    /// whether the pill currently looks bad. Whole domain, both directions.
    func testIsProbeablePartitionsOnEndpointPresence() {
        let probe = CountingProbe(.embedded)

        XCTAssertTrue(LinkMonitor(source: .fixed(endpoint()), probe: probe).isProbeable,
                      "POS: a resolved endpoint is probeable")

        for arm in [GatewayConfig.local(.ready),
                    GatewayConfig.local(.noProvider),
                    GatewayConfig.local(.checking),
                    GatewayConfig.absent,
                    GatewayConfig.malformed(raw: "wat", reason: .notAURL)] {
            XCTAssertFalse(LinkMonitor(source: .fixed(arm), probe: probe).isProbeable,
                           "NEG: \(arm) has no endpoint and must not offer a re-probe")
        }
    }

    // MARK: - wiring: the legs above stay green with the button unconditional

    /// 🔴 CORRECT-BUT-UNWIRED. Every behavioural leg above passes with
    /// `HomeView` still handing `LinkCard` an unconditional closure — the
    /// arrow would render on `.local`, tap cleanly, and do nothing, which is
    /// a dead control rather than a corrupting one but still a lie. Only a
    /// census sees the call site.
    func testHomeViewChoosesTheRetryArmFromIsProbeable() throws {
        let code = Self.codeOnly(try Self.source("HomeView.swift"))
        XCTAssertTrue(code.contains("link.isProbeable"),
                      "POS: the call site must choose the arm from the predicate")
        XCTAssertTrue(code.contains("LinkCard(state: link.state"),
                      "POS control: the LinkCard call site is still where this leg thinks it is")
        XCTAssertFalse(code.contains("zzzNoSuchSymbol"),
                       "NEG control: the corpus loaded and the matcher discriminates")
    }

    /// The optionality is the structural half, and it is what makes the
    /// absence UNFORGEABLE: a non-optional closure cannot express "there is
    /// no act here", so the view would be back to rendering a control and
    /// hoping the handler behaves.
    func testTheRetryClosureIsOptionalAndItsButtonIsConditional() throws {
        let code = Self.codeOnly(try Self.source("HomeView.swift"))
        XCTAssertTrue(code.contains("let onRetry: (() -> Void)?"),
                      "POS: the retry closure must be OPTIONAL, not a defaulted no-op")
        XCTAssertTrue(code.contains("if let onRetry = onRetry"),
                      "POS: no button is rendered when there is nothing to probe")
        XCTAssertFalse(code.contains("var onRetry: (() -> Void)? = nil"),
                       "NEG: a DEFAULT would let a call site omit the decision entirely")
    }

    // MARK: - ENROLL NODE

    /// The fabricated instruction must be gone from the whole app corpus, not
    /// merely from the button — a toast literal moved to a helper is still
    /// reachable.
    func testNoControlInstructsTheOperatorToScanADeviceThisBuildCannotPair() throws {
        let corpus = Self.codeOnly(try Self.allSourceText()).uppercased()
        XCTAssertFalse(corpus.contains("SCAN THE NEW DEVICE"),
                       "the fabricated enrollment instruction is still reachable")
        XCTAssertTrue(corpus.contains("ENROLL NODE"),
                      "POS control: the control itself still exists — this census can see it")
    }

    /// Disabled on VERB ABSENCE and rendered WITH ITS REASON. The negative
    /// half is load-bearing for the same reason it is on BROADCAST/PING: a
    /// `resolution`-conditioned disablement would assert the verb exists and
    /// is merely unreachable.
    func testEnrollIsTerminallyDisabledOnVerbAbsence() throws {
        let slice = try Self.slice(of: Self.codeOnly(try Self.source("NodesView.swift")),
                                   from: "private var enrollButton",
                                   to: "private func iconWell")
        XCTAssertTrue(slice.contains(".disabled(true)"),
                      "POS: ENROLL must be disabled by a LITERAL true, not by a condition")
        XCTAssertTrue(slice.contains("Self.absentEnrollmentLabel"),
                      "POS: the reason must be rendered, not merely implied by grey")
        XCTAssertFalse(slice.contains("onToast("),
                       "NEG: no toast — any sentence here narrates an act with no implementation")
        XCTAssertFalse(slice.contains("resolution"),
                       "NEG: no link-conditioned enablement; the verb is absent, not unreachable")
        XCTAssertFalse(slice.contains("zzzNoSuchSymbol"),
                       "NEG control: the slice did not escape its anchors")
    }

    /// The sentence itself: names the absence, names no host, promises no
    /// retry. Same shape as `HomeView.absentVerbLabel`, asserted rather than
    /// asserted-by-comment.
    func testTheEnrollReasonNamesTheAbsenceAndNotAHost() {
        let label = NodesView.absentEnrollmentLabel
        XCTAssertTrue(label.uppercased().contains("NO ENROLLMENT TRANSPORT"),
                      "the reason must name the missing VERB")
        XCTAssertFalse(label.uppercased().contains("UNREACHABLE"),
                       "NEG: an absent verb is not an unreachable host")
        XCTAssertNotEqual(label, "ENROLL NODE",
                          "vacuity: the label collapsed to the bare control name")
    }

    // MARK: - corpus helpers

    /// Comments stripped, for the same reason `AttachCoherenceTests` strips
    /// them: this file's own doc comments quote the retired strings, and a
    /// census whose corpus includes prose cannot tell a USE from a mention.
    private static func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slash = line.range(of: "//") else { return line }
                return line[line.startIndex ..< slash.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    private static func source(_ name: String) throws -> String {
        let text = try String(contentsOf: sourceURL("Sources/ZeusApp/\(name)"), encoding: .utf8)
        XCTAssertGreaterThan(text.count, 500, "VOID: \(name) did not load")
        return text
    }

    private static func allSourceText() throws -> String {
        let fm = FileManager.default
        var text = ""
        for dir in ["Sources/ZeusApp", "Sources/ZeusCoreFFI"] {
            guard let e = fm.enumerator(at: sourceURL(dir), includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        XCTAssertGreaterThan(text.count, 10_000, "VOID: the source corpus did not load")
        return text
    }

    private static func slice(of source: String, from open: String, to close: String) throws -> String {
        guard let start = source.range(of: open),
              let end = source.range(of: close, range: start.upperBound ..< source.endIndex)
        else {
            XCTFail("VOID — an anchor moved (\(open) … \(close)); this leg measured nothing")
            return ""
        }
        return String(source[start.upperBound ..< end.lowerBound])
    }
}
