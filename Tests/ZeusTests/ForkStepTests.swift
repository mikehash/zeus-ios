import XCTest
@testable import Zeus

/// ③ — the fork step, `Commission.deployment`/`gatewayURL`, and the single
/// endpoint parser both resolution arms call.
///
/// Every source-reading leg here carries a POS control in the same invocation:
/// a needle that reads 0 because the path is wrong is indistinguishable from a
/// needle that reads 0 because the tree is clean, and the second is the only
/// one that means anything.
final class ForkStepTests: XCTestCase {

    private let k = GatewayConfig.urlKey
    private let t = GatewayConfig.tokenKey

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
        return try String(contentsOf: root.appendingPathComponent("Sources/ZeusApp/\(name)"),
                          encoding: .utf8)
    }

    /// Code lines only. A docstring naming the needle it forbids is itself a
    /// hit — this file's siblings tripped that three times in one night.
    private func codeLines(_ src: String) -> [String] {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    // MARK: - ① one parser, two arms

    /// THE EQUALITY LEG. Not two tables that happen to agree — the same input
    /// driven through both production entry points and asserted equal.
    ///
    /// A second parser in the REMOTE arm would pass every per-arm table in
    /// this suite: both arms return a `GatewayConfig`, both compile, and the
    /// only symptom is a string one path accepts and the other rejects.
    func testBothArmsAgreeOnEveryMalformedInput() {
        let inputs = ["not a url at all", "://nohost", "ftp://x.example",
                      "http://", "https://ok.example:8080"]
        for raw in inputs {
            let viaEnv = GatewayConfig.resolveFromEnvironment(from: [k: raw])
            let viaCommission = GatewayConfig.resolve(
                from: [:],
                store: InMemoryCommissionStore(seed: remoteCommission(url: raw))
            ).config
            XCTAssertEqual(viaEnv, viaCommission,
                           "the two arms disagree on \"\(raw)\" — a second parser exists")
        }
    }

    /// VACUITY GUARD on the leg above: if every input resolved to the same
    /// value the equality would be satisfied by an identity and prove nothing.
    func testTheAgreementLegHasInputsThatActuallyDiffer() {
        let a = GatewayConfig.resolveFromEnvironment(from: [k: "not a url at all"])
        let b = GatewayConfig.resolveFromEnvironment(from: [k: "https://ok.example:8080"])
        XCTAssertNotEqual(a, b, "the corpus must span more than one verdict")
    }

    /// The census ruled beside the equality leg: an extracted pure function
    /// with one arm quietly re-inlined is indistinguishable from this one at
    /// the type, so the CALL SITES are counted, not just the behaviour.
    func testParseEndpointHasExactlyTwoProductionCallSites() throws {
        let src = try source("GatewayConfig.swift")
        let code = codeLines(src)
        XCTAssertEqual(code.filter { $0.contains("static func parseEndpoint(") }.count, 1,
                       "POS control: the declaration is in this file")
        // The declaration reads `parseEndpoint(raw: String` and matches a naive
        // call needle — the self-match class, one layer down from a comment.
        let calls = code.filter { $0.contains("parseEndpoint(raw:") && !$0.contains("static func") }
        XCTAssertEqual(calls.count, 2,
                       "exactly two production callers — resolveFromEnvironment and the REMOTE arm; found \(calls)")
    }

    // MARK: - ② deployment as a stored, optional choice

    private func remoteCommission(url: String?) -> Commission {
        var c = Commission()
        c.provider = "anthropic-x"
        c.deployment = .remote
        c.gatewayURL = url
        return c
    }

    func testRemoteWithAnEndpointResolvesThatEndpoint() {
        let r = GatewayConfig.resolve(
            from: [:], store: InMemoryCommissionStore(seed: remoteCommission(url: "https://core.example")))
        guard case let .resolved(endpoint) = r.config else {
            return XCTFail("expected .resolved, got \(r.config)")
        }
        XCTAssertEqual(endpoint.url.absoluteString, "https://core.example")
        XCTAssertNil(endpoint.token, "no Keychain producer exists yet; a stubbed token would be a lie")
        XCTAssertEqual(r.source, .commission)
    }

    /// REMOTE chosen, no URL yet. `.absent` is the honest config — its
    /// documented meaning is *nothing is listening*, which is exactly true —
    /// but the SOURCE is `.commission`, because somebody did choose.
    func testRemoteWithoutAnEndpointIsAbsentButCommissionSourced() {
        let r = GatewayConfig.resolve(
            from: [:], store: InMemoryCommissionStore(seed: remoteCommission(url: nil)))
        XCTAssertEqual(r.config, .absent)
        XCTAssertEqual(r.source, .commission,
                       ".unset would say nobody chose, and the operator chose REMOTE")
    }

    /// The precedence edge, restated for the arm ③ adds: an explicit
    /// `ZEUS_GATEWAY_URL` still beats a persisted REMOTE endpoint.
    func testEnvironmentStillBeatsAPersistedRemoteEndpoint() {
        let r = GatewayConfig.resolve(
            from: [k: "https://env.example", t: "tok"],
            store: InMemoryCommissionStore(seed: remoteCommission(url: "https://persisted.example")))
        XCTAssertEqual(r.source, .environment)
        XCTAssertEqual(r.config.summary.contains("env.example"), true)
    }

    /// A record written before the fork screen existed resolves the way it
    /// already did at ②. `nil` is not a third mode.
    func testLegacyRecordWithNoDeploymentStillResolvesLocal() throws {
        let json = #"{"route":"byok","callsign":"ATLAS","node_enrolled":true,"provider":"anthropic-x"}"#
        let c = try JSONDecoder().decode(Commission.self, from: Data(json.utf8))
        XCTAssertNil(c.deployment)
        XCTAssertNil(c.gatewayURL)
        let r = GatewayConfig.resolve(from: [:], store: InMemoryCommissionStore(seed: c))
        XCTAssertEqual(r.config, .local(.ready))
        XCTAssertEqual(r.source, .commission)
    }

    func testDeploymentAndGatewayURLRoundTrip() throws {
        let c = remoteCommission(url: "https://core.example")
        let back = try JSONDecoder().decode(Commission.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
        XCTAssertEqual(back.deployment, .remote)
        XCTAssertEqual(back.gatewayURL, "https://core.example")
    }

    // MARK: - the writer, and the screen that calls it

    func testRecordDeploymentIsTheWriterAndLocalClearsAStaleEndpoint() {
        var c = remoteCommission(url: "https://stale.example")
        c.recordDeployment(.local)
        XCTAssertEqual(c.deployment, .local)
        XCTAssertNil(c.gatewayURL,
                     "a LOCAL commission holding a REMOTE endpoint is what a later switch silently adopts")
    }

    func testRecordDeploymentRemoteKeepsTheEndpoint() {
        var c = remoteCommission(url: "https://core.example")
        c.recordDeployment(.remote)
        XCTAssertEqual(c.gatewayURL, "https://core.example")
    }

    /// The call-site guard. Five times on this branch a value was asserted
    /// while the site that WRITES it was deletable with every leg green; the
    /// CTA closure is not reachable in-process, so the site is guarded by a
    /// source census with a POS that VOIDs on a wrong path.
    func testTheForkScreenCallsTheWriter() throws {
        let src = try source("Commissioning.swift")
        let code = codeLines(src)
        XCTAssertEqual(code.filter { $0.contains("mutating func recordDeployment") }.count, 1,
                       "POS control: the declaration is in this file")
        XCTAssertEqual(code.filter { $0.contains("commission.recordDeployment(") }.count, 1,
                       "the fork screen's CONTINUE is the sole caller")
    }

    /// The needle the CLAIM is about: assignments to the FIELD, not calls to
    /// the writer's NAME.
    ///
    /// The leg above counts `commission.recordDeployment(` == 1 and passed
    /// while two `RouteCard` closures wrote `commission.deployment` directly on
    /// tap — a writer census is blind to every assignment that bypasses the
    /// writer, which is precisely the defect a sole-writer claim asserts is
    /// impossible. Cardinality, not absence: the field must be assigned, so
    /// this counts the assignments a production path is allowed to make.
    ///
    /// Permitted in `Sources`: the memberwise init (`self.deployment =`), the
    /// decoder (`deployment = try`), `recordDeployment`'s body, and the
    /// backstep clear (`next.commission.deployment = nil`). A fifth is the
    /// defect. `commission.deployment =` — an assignment THROUGH the view's
    /// record — must read exactly 0.
    func testNoViewSiteAssignsTheDeploymentField() throws {
        let src = try source("Commissioning.swift")
        let code = codeLines(src)

        XCTAssertGreaterThan(code.filter { $0.contains("deployment") }.count, 4,
                             "POS control: `deployment` is live in this file — 0 here means a wrong path, VOID not pass")

        // The backstep clear is the ONE permitted assignment through a
        // `commission.` path and it is pinned by its whole trimmed line, not
        // excluded by a substring: an exclusion wide enough to spare it is wide
        // enough to spare the defect it was written to catch.
        let permitted = "next.commission.deployment = nil"
        let through = code.map { $0.trimmingCharacters(in: .whitespaces) }
                          .filter { $0.contains("commission.deployment =") }
        XCTAssertEqual(through.filter { $0 == permitted }.count, 1,
                       "POS control: the backstep clear is present — 0 means the needle stopped reading this file")
        XCTAssertEqual(through.filter { $0 != permitted }, [],
                       "a view site assigning the record field bypasses recordDeployment: \(through)")
    }

    /// Preselection is rendered, not stored: a fresh commission has made no
    /// choice, and the highlight is derived.
    func testPreselectionIsNotAStoredChoice() {
        XCTAssertNil(Commission().deployment,
                     "a screen the operator has merely LOOKED at must not read as a decision")
    }

    // MARK: - ③ totality over the step set

    /// The rail denominator and the narration deck must both grow with the
    /// case set. `narration` is a `switch` with no `default`, so a missing arm
    /// is a compile error — this leg guards the OTHER direction: an arm that
    /// exists but is empty.
    func testEveryStepNarratesAndTheSetIsNotEmpty() {
        XCTAssertGreaterThan(CommissioningStep.allCases.count, 1,
                             "POS control: a one-member set makes totality vacuous")
        for step in CommissioningStep.allCases {
            for record in [Commission(), { var c = Commission(); c.provider = "anthropic"; return c }()] {
                XCTAssertFalse(step.narration(commission: record)
                                   .trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(step) ships mute")
            }
        }
    }

    // MARK: - The done headline states RECORD facts, one arm each
    //
    // TWO EQUALITY assertions, never `Set(...).count == 2`: a cardinality leg
    // is satisfied by two WRONG constants and by a SWAPPED branch, which are
    // the two regressions that can actually happen here. Equality names which
    // arm broke.

    func testDoneHeadlineNoProviderArm() {
        XCTAssertEqual(CommissioningStep.done.narration(commission: Commission()),
                       "No provider on your record. I can't answer until one is set.")
    }

    func testDoneHeadlineProviderOnRecordArm() {
        var record = Commission()
        record.provider = Commission.routesProviderID
        XCTAssertEqual(CommissioningStep.done.narration(commission: record),
                       "Provider on your record. I arm on the next screen.")
    }

    /// The two arms must DIFFER. A `narration` that ignored its argument
    /// satisfies neither equality leg — but a future refactor that collapses
    /// them onto one constant would have to break both, and this states the
    /// invariant those two legs exist to protect in one line.
    func testDoneHeadlineArmsAreNotTheSameSentence() {
        var record = Commission()
        record.provider = Commission.routesProviderID
        XCTAssertNotEqual(CommissioningStep.done.narration(commission: Commission()),
                          CommissioningStep.done.narration(commission: record),
                          "the done headline must be a function of the record, not a constant")
    }

    /// The retired sentence claimed a CORE verdict at a step that runs before
    /// `CoreArming.arm` exists in the process. It must not come back.
    func testNoCoreClaimSurvivesInTheDoneHeadline() {
        var record = Commission()
        record.provider = Commission.routesProviderID
        for arm in [CommissioningStep.done.narration(commission: Commission()),
                    CommissioningStep.done.narration(commission: record)] {
            for banned in ["nominal", "live", "ready", "armed"] {
                XCTAssertFalse(arm.lowercased().contains(banned),
                               "the done step cannot source a core fact: \(banned) in \(arm)")
            }
        }
        XCTAssertTrue(CommissioningStep.welcome.narration(commission: Commission())
                          .lowercased().contains("live"),
                      "POS control: the needle IS present elsewhere in the deck")
    }

    func testForkSitsBetweenWelcomeAndAuth() {
        XCTAssertEqual(Backstep.previous(of: .fork), .welcome)
        XCTAssertEqual(Backstep.previous(of: .auth), .fork)
    }

    /// The per-step re-ask rule, second member. Asserted as a DIFFERENCE
    /// between two entries on the same input, so a policy that discarded
    /// everywhere would fail it.
    func testEnteringForkDiscardsTheChoiceAndItsEndpoint() {
        let state = Backstep.Entry(commission: remoteCommission(url: "https://core.example"),
                                   scanning: true, authed: true)
        let intoFork = Backstep.entering(.fork, from: state)
        XCTAssertNil(intoFork.commission.deployment, "a step you returned to must be re-askable")
        XCTAssertNil(intoFork.commission.gatewayURL)

        let intoCallsign = Backstep.entering(.callsign, from: state)
        XCTAssertEqual(intoCallsign.commission.deployment, .remote,
                       "the discard is scoped to .fork, not applied to every entry")
        XCTAssertEqual(intoCallsign.commission.gatewayURL, "https://core.example")
    }

    func testEnteringForkKeepsTheAnswersThatArentTheForkQuestion() {
        var c = remoteCommission(url: "https://core.example")
        c.callsign = "ATLAS"
        let next = Backstep.entering(.fork, from: .init(commission: c, scanning: false, authed: true))
        XCTAssertEqual(next.commission.callsign, "ATLAS")
        XCTAssertEqual(next.commission.provider, "anthropic-x")
        XCTAssertTrue(next.authed)
    }

    /// The prose an operator types against, which no compiler checks.
    func testLaunchArgsProseEnumeratesEveryStep() throws {
        let src = try source("LaunchArgs.swift")
        XCTAssertTrue(src.contains("-zeusStep"), "POS control: the flag is documented in this file")
        for step in CommissioningStep.allCases {
            XCTAssertTrue(src.contains(step.rawValue),
                          "-zeusStep prose omits \(step.rawValue); the parser accepts it and the doc doesn't say so")
        }
    }

    /// The rider. An empty-closure default ships an affordance that renders,
    /// takes the tap and does nothing — a lie with a tap target.
    func testSessionViewComposerHasNoDefaultedSendClosure() throws {
        let code = codeLines(try source("SessionView.swift"))
        XCTAssertEqual(code.filter { $0.contains("var onSend:") }.count, 1,
                       "POS control: the declaration is in this file")
        XCTAssertTrue(code.filter { $0.contains("var onSend:") }
                        .allSatisfy { !$0.contains("=") },
                      "onSend must have no default")
    }

    /// (b) — the same rule one level up. A memberwise default on
    /// `disarmReason` lets the next `SessionView(` omit readiness and render
    /// a live composer over an unarmed core: the defect the parameter exists
    /// to close, re-entering through omission rather than through logic.
    func testSessionViewDisarmReasonHasNoDefault() throws {
        let code = codeLines(try source("SessionView.swift"))
        let decls = code.filter { $0.contains("var disarmReason:") }
        XCTAssertEqual(decls.count, 1, "POS control: the property is declared in this file")
        XCTAssertTrue(decls.allSatisfy { !$0.contains("=") },
                      "disarmReason must have no memberwise default")
    }

    /// ③'s repair button. Asserts the LABEL and the DESTINATION together:
    /// the label alone passes on a control that navigates nowhere, and the
    /// destination alone passes on a button that says something else. The
    /// point of this affordance is that the words and the effect are the
    /// same thing — a repair naming a fix its own slot can perform.
    func testDoneStepRepairButtonNamesTheStepItActuallyReturnsTo() throws {
        let code = codeLines(try source("Commissioning.swift"))
        let hits = code.filter { $0.contains("SET A PROVIDER") }
        XCTAssertEqual(hits.count, 1, "exactly one repair control")
        XCTAssertTrue(hits[0].contains("step = .routes"),
                      "the repair must act in its slot: \(hits[0])")
        XCTAssertEqual(code.filter { $0.contains("if commission.provider == nil") }.count, 1,
                       "gated on the RECORD, the only fact this step owns")
    }

    /// The vacuity assert the leg above cannot make about itself: the button
    /// is CONDITIONAL. A control rendered unconditionally passes every needle
    /// above while telling a fully-commissioned operator to go set a provider
    /// they already set.
    func testRepairButtonIsWithheldWhenTheRecordHasAProvider() throws {
        var withProvider = Commission()
        withProvider.recordRoutesChoice(providerID: "anthropic", model: "m")
        XCTAssertNotNil(withProvider.provider)
        XCTAssertNil(Commission().provider,
                     "a fresh record has no provider; the two arms must differ")
    }
}
