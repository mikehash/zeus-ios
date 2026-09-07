import XCTest
@testable import Zeus

/// Legs for backward navigation through commissioning.
///
/// ⚠️ APERTURE, stated here rather than left implied. `Backstep` is a pure value
/// type and every leg below runs against it directly. NOTHING HERE RENDERS. The
/// header's leading well, its `.opacity(0)` / `.disabled` / `.accessibilityHidden`
/// wiring, and the `CONTINUE` button added to the verified `.auth` branch are
/// *view* code, unreachable from a test process without a host app driving a real
/// layout pass. What is guarded here is the decision — where back goes, what it
/// forgets, and when the control exists. What is NOT guarded is whether the view
/// asks. The store frames from `capture_store_screens.sh` are the only evidence
/// of the rendering, and they are photographs, not assertions.
///
/// Every leg was written against its VACUOUS form first and kept only where the
/// vacuous form fails on a stub — noted per leg where the distinction is subtle.
final class BackstepTests: XCTestCase {

    // MARK: - the order

    /// VACUOUS FORM: "previous(of:) returns a step or nil for every case" —
    /// passes on `return nil`, which is the forward-only app we started with.
    /// The kept form pins the actual predecessor at every index.
    ///
    /// ③ CHANGED THIS LIST ON PURPOSE and the leg is why that was a decision
    /// rather than an accident: inserting `.fork` moved `.auth`'s predecessor,
    /// the pin failed, and the new order was confirmed by hand. A leg that
    /// derived the order from `allCases` would have gone green on the insert
    /// and told nobody.
    func testPreviousIsTheImmediatePredecessorInDeclaredOrder() {
        XCTAssertEqual(Backstep.previous(of: .fork), .welcome)
        XCTAssertEqual(Backstep.previous(of: .auth), .fork)
        XCTAssertEqual(Backstep.previous(of: .routes), .auth)
        XCTAssertEqual(Backstep.previous(of: .nodes), .routes)
        XCTAssertEqual(Backstep.previous(of: .callsign), .nodes)
        XCTAssertEqual(Backstep.previous(of: .done), .callsign)
    }

    func testWelcomeHasNoPredecessorItIsTheFirstStep() {
        XCTAssertNil(Backstep.previous(of: .welcome))
    }

    /// The rail's denominator is derived from `allCases`; so is this. If a step
    /// is inserted, back must walk the NEW order without an edit here — the leg
    /// that would otherwise go stale silently is the one asserting a literal list.
    func testEveryNonFirstStepHasAPredecessorAndItIsNotItself() {
        let all = CommissioningStep.allCases
        for (i, step) in all.enumerated() where i > 0 {
            let prev = Backstep.previous(of: step)
            XCTAssertNotNil(prev, "\(step) has no predecessor")
            XCTAssertNotEqual(prev, step, "\(step) is its own predecessor")
            XCTAssertEqual(prev, all[i - 1])
        }
    }

    // MARK: - availability

    /// `stepIdx > 0 && step !== 'done'` (:452). Both clauses matter and a leg
    /// that only checks `.welcome` would pass on an implementation missing the
    /// second — so `done` is asserted beside it, with the explicit note that it
    /// HAS a predecessor and is hidden anyway.
    func testControlIsHiddenAtTheFirstStepAndAtDone() {
        XCTAssertFalse(Backstep.isAvailable(at: .welcome))
        XCTAssertFalse(Backstep.isAvailable(at: .done))
        XCTAssertNotNil(Backstep.previous(of: .done),
                        "done is excluded by policy, not by absence of a predecessor")
    }

    func testControlIsAvailableAtEveryStepBetween() {
        for step in [CommissioningStep.auth, .routes, .nodes, .callsign] {
            XCTAssertTrue(Backstep.isAvailable(at: step), "\(step) should offer back")
        }
    }

    /// VACUITY: the two verdicts must not have collapsed to one. An
    /// `isAvailable` returning a constant passes both preceding legs' shapes in
    /// isolation if either is deleted; this fails whenever the function is total
    /// in the wrong way.
    func testAvailabilityIsNotConstantOverTheStepOrder() {
        let verdicts = Set(CommissioningStep.allCases.map(Backstep.isAvailable(at:)))
        XCTAssertEqual(verdicts, [true, false])
    }

    // MARK: - what a backward entry keeps

    private func entry(
        route: Commission.Route = .byok,
        callsign: String = "MIGUEL",
        nodeEnrolled: Bool = true,
        scanning: Bool = true,
        authed: Bool = true
    ) -> Backstep.Entry {
        .init(
            commission: Commission(route: route, callsign: callsign, nodeEnrolled: nodeEnrolled),
            scanning: scanning,
            authed: authed
        )
    }

    /// The operator's two answers survive every backward entry. VACUOUS FORM:
    /// "entering() returns an Entry" — passes on `return state`, which is also
    /// the correct answer for three of the four fields, so the discard legs
    /// below are what give this one its teeth.
    func testRouteAndCallsignSurviveEveryBackwardEntry() {
        for target in CommissioningStep.allCases {
            let out = Backstep.entering(target, from: entry())
            XCTAssertEqual(out.commission.route, .byok, "route lost entering \(target)")
            XCTAssertEqual(out.commission.callsign, "MIGUEL", "callsign lost entering \(target)")
        }
    }

    func testScanningIsDiscardedOnEveryBackwardEntry() {
        for target in CommissioningStep.allCases {
            XCTAssertFalse(Backstep.entering(target, from: entry()).scanning,
                           "scanning survived into \(target)")
        }
    }

    /// A recorded SKIP must be re-askable — but only at the step that asks.
    /// Discarding it everywhere would rewrite a decision while stepping past it.
    func testNodeEnrolledIsDiscardedOnlyWhenReenteringNodes() {
        XCTAssertFalse(Backstep.entering(.nodes, from: entry()).commission.nodeEnrolled)
        for target in CommissioningStep.allCases where target != .nodes {
            XCTAssertTrue(Backstep.entering(target, from: entry()).commission.nodeEnrolled,
                          "nodeEnrolled was rewritten while entering \(target)")
        }
    }

    /// VACUITY for the pair above: preserve and discard must be DIFFERENT
    /// outcomes for the same input. A policy that returned its input unchanged
    /// passes "route survives" and a policy that cleared everything passes
    /// "scanning discarded"; only this fails both.
    func testEnteringNodesDiffersFromEnteringCallsignOnTheSameInput() {
        XCTAssertNotEqual(
            Backstep.entering(.nodes, from: entry()),
            Backstep.entering(.callsign, from: entry())
        )
    }

    // MARK: - authed: the ruling, both legs

    /// LEG 1 — a completed verification is NOT thrown away by stepping back.
    /// This is the ruled behaviour and it is the one that creates the dead end
    /// the next leg closes; the two are written together on purpose.
    func testAuthedSurvivesABackwardEntryIntoAuth() {
        XCTAssertTrue(Backstep.entering(.auth, from: entry(authed: true)).authed)
    }

    func testAuthedSurvivesEveryBackwardEntryNotJustAuth() {
        for target in CommissioningStep.allCases {
            XCTAssertTrue(Backstep.entering(target, from: entry(authed: true)).authed,
                          "authed was discarded entering \(target)")
        }
    }

    /// LEG 2 — the affordance that makes leg 1 safe.
    ///
    /// A preserved `authed` is a TRAP unless the verified branch can move
    /// forward, and this is the strongest statement a test process can make
    /// about it without rendering: the branch's forward writer must exist in
    /// shipping source. Greps the file rather than the view because a SwiftUI
    /// body is not observable here.
    ///
    /// POSITIVE CONTROLS in the same invocation, so a mis-pointed read cannot
    /// pass as a clean hit: the file must contain the branch itself and the
    /// badge string it renders. Without them a wrong path yields "0 of 0".
    func testVerifiedAuthBranchHasAForwardWriterInShippingSource() throws {
        let source = try commissioningSource()

        XCTAssertTrue(source.contains("case .auth:"), "POS CONTROL: wrong file or renamed step")
        XCTAssertTrue(source.contains("OPERATOR VERIFIED"), "POS CONTROL: badge string missing")

        // The affordance. Named by its writer, not by its title, so renaming the
        // button's label does not silently retire the guard.
        let branch = try XCTUnwrap(source.range(of: "if authed {"))
        let elseArm = try XCTUnwrap(source.range(of: "} else {", range: branch.upperBound ..< source.endIndex))
        let verified = String(source[branch.upperBound ..< elseArm.lowerBound])

        XCTAssertTrue(verified.contains("step = .routes"),
                      "the verified branch has no forward writer — OPERATOR VERIFIED is a dead end")
    }

    /// The dead end was never only about back-nav: `LaunchArgs.initialStep` can
    /// land on `.auth` directly. Pins that the seam still names the step, so the
    /// reason recorded at the site stays true.
    func testSeededEntryCanLandOnAuthWhichIsWhyTheBranchNeedsItsOwnCTA() {
        XCTAssertNotNil(CommissioningStep(rawValue: "auth"))
    }

    // MARK: - the round trip, as a state walk

    /// Enter `.auth` backward with `authed == true`, then forward again: the
    /// route is still selected. The forward half is `step = .routes` with no
    /// state mutation, so the assertion is that nothing on the backward half
    /// touched `route`.
    func testBackIntoAuthThenForwardAgainKeepsTheSelectedRoute() {
        let start = entry(route: .byok, authed: true)
        let atAuth = Backstep.entering(.auth, from: start)

        XCTAssertTrue(atAuth.authed)
        XCTAssertEqual(atAuth.commission.route, .byok)

        // Forward is not a Backstep operation — it writes `step` only. Same
        // value, restated, is exactly the claim.
        XCTAssertEqual(atAuth.commission.route, start.commission.route)
    }

    /// Walking all the way back to `.welcome` one step at a time keeps the
    /// operator's answers and clears only the re-askable one.
    func testWalkingBackFromDoneToWelcomeKeepsAnswersAndClearsTheSkip() {
        // Subject is BACKSTEP, not the route mode; `.managed` is decode-only
        // (Commissioning.swift:120) so the fixture uses a mode the app can
        // still produce. What is asserted below is that back-nav PRESERVES
        // the route, whatever it is.
        var state = entry(route: .byok, callsign: "ATLAS", nodeEnrolled: true, scanning: true)
        var step = CommissioningStep.done

        while let prev = Backstep.previous(of: step) {
            state = Backstep.entering(prev, from: state)
            step = prev
        }

        XCTAssertEqual(step, .welcome)
        XCTAssertEqual(state.commission.route, .byok)
        XCTAssertEqual(state.commission.callsign, "ATLAS")
        XCTAssertFalse(state.commission.nodeEnrolled, "the walk passed through .nodes")
        XCTAssertFalse(state.scanning)
        XCTAssertTrue(state.authed)
    }

    // MARK: - source helper

    private func commissioningSource() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // repo
        let file = root.appendingPathComponent("Sources/ZeusApp/Commissioning.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }
}
