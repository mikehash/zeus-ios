import XCTest
import SwiftUI
@testable import Zeus

/// The ZEUS tab is the cold-start destination: `LaunchArgs.initialTab` returns
/// `.zeus` unconditionally in release, so every commissioned operator lands
/// here on every launch. The screen's whole claim is that no value on it is a
/// literal, which is exactly the claim the three removed defects
/// (`"LINKED · KITCHEN NODE"`, `nodeOnline = true`, `"last seen t-12min"`)
/// each violated while looking correct in a screenshot.
///
/// These legs assert on the derivation, not on the rendering. A SwiftUI body
/// is not observable in-process, so the derived values are computed properties
/// with internal access and each is exercised across the arms that produce it.
@MainActor
final class HomeViewTests: XCTestCase {

    /// Builds a view over injected state. The transport factory is a closure
    /// that never streams: these legs are about derivation from state, and a
    /// live turn would make them timing-dependent for no gain.
    // MARK: - Operator line

    /// The callsign comes from the restored commission. A commission is
    /// carried through the environment, which a unit test cannot inject into a
    /// value type's `@Environment` — so this leg tests the derivation directly
    /// against the same rule the property applies.
    func testOperatorLineUppercasesCallsign() {
        let line = HomeView.operatorLine(for: "miguel")
        XCTAssertEqual(line, "OPERATOR\u{00A0}·\u{00A0}MIGUEL")
    }

    /// The callsign step can be completed blank, so an empty callsign is a
    /// reachable state and not a defensive branch. It must not render as a
    /// dangling separator, which reads as a rendering bug rather than as an
    /// empty field.
    func testOperatorLineNamesUnnamedRatherThanTrailingSeparator() {
        XCTAssertEqual(HomeView.operatorLine(for: ""), "OPERATOR\u{00A0}·\u{00A0}UNNAMED")
        XCTAssertEqual(HomeView.operatorLine(for: "   "), "OPERATOR\u{00A0}·\u{00A0}UNNAMED")
        // Vacuity floor: the two arms genuinely differ, so a stub returning one
        // constant could not satisfy both.
        XCTAssertNotEqual(HomeView.operatorLine(for: ""), HomeView.operatorLine(for: "miguel"))
    }

    // MARK: - Latency

    /// THE CENTRAL LEG. Latency is a measurement or it is absent. A remembered
    /// value describes a gateway that has since stopped answering — the exact
    /// shape of the `"last seen t-12min"` defect, which was a number nothing
    /// recorded rendered in a slot that reads as data.
    func testLatencyIsEmDashUnderEveryNonLinkedState() {
        let nonLinked: [LinkState] = [
            .unconfigured,
            .probing,
            .unreachable(host: "zeus.local", reason: "timeout")
        ]
        for state in nonLinked {
            XCTAssertEqual(
                HomeView.latencyValue(for: state), "—",
                "a non-linked state must not publish a latency: \(state)"
            )
        }
        // Floor: the linked arm DOES publish one, so "—" is not a constant.
        XCTAssertEqual(HomeView.latencyValue(for: .linked(host: "zeus.local", ms: 41)), "41MS")
    }

    // MARK: - Turns

    /// A turn counts once the agent's caret has cleared. Counting user
    /// messages, or counting a streaming caret, would increment before the
    /// gateway had answered anything — a count that leads the event it claims
    /// to report.
    func testTurnsCountsOnlySettledAgentMessages() {
        let streaming = [
            Message(role: .user, text: "hello"),
            Message(role: .agent, text: "part", streaming: true)
        ]
        XCTAssertEqual(HomeView.turnsValue(for: streaming), "0")

        let settled = [
            Message(role: .user, text: "hello"),
            Message(role: .agent, text: "done", streaming: false)
        ]
        XCTAssertEqual(HomeView.turnsValue(for: settled), "1")

        XCTAssertEqual(HomeView.turnsValue(for: []), "0")
    }

    // MARK: - Resume

    /// The action cannot offer to resume a conversation that never happened.
    func testResumeLabelTracksTranscriptState() {
        XCTAssertEqual(HomeView.resumeLabel(for: []), "START A SESSION")
        XCTAssertEqual(
            HomeView.resumeLabel(for: [Message(role: .user, text: "hi")]),
            "RESUME SESSION"
        )
    }

    /// An empty preview slot stays empty. A placeholder sentence there is
    /// indistinguishable from a real short reply.
    func testLastLineIsEmptyRatherThanPlaceholder() {
        XCTAssertEqual(HomeView.lastLine(for: []), "")
        XCTAssertEqual(HomeView.lastLine(for: [Message(role: .agent, text: "   ")]), "")
        XCTAssertEqual(HomeView.lastLine(for: [Message(role: .agent, text: "ack")]), "ack")
    }

    // MARK: - Activity

    /// The cap is applied AFTER reversing, so the newest frames survive it.
    /// Capping first would render the six OLDEST frames under a heading that
    /// says nothing about age — stale telemetry that looks live.
    func testRecentActivityKeepsNewestNotOldest() {
        let frames = (1...10).map { SessionActivity(.iteration($0)) }
        let recent = HomeView.recentActivity(from: frames)
        XCTAssertEqual(recent.count, 6)
        XCTAssertEqual(recent.first?.label, "iteration 10")
        XCTAssertEqual(recent.last?.label, "iteration 5")
    }

    func testRecentActivityIsEmptyForNoFrames() {
        XCTAssertTrue(HomeView.recentActivity(from: []).isEmpty)
    }

    // MARK: - The orb

    /// PRE-REGISTERED, and the vacuous form is named first so it cannot be
    /// written later by accident: "`orbLevel` returns a Double for every
    /// state" passes on `return 0.2`, which is the defect — a renderer
    /// argument that never varies while looking like a live meter.
    ///
    /// The discriminating form is that the value DIFFERS across the phases
    /// where the renderer reads it. `level` is consumed only in `.speaking`
    /// (`DeviceOrb.swift:70`), so this asserts the split lands on exactly the
    /// boundary `orbMode` draws: the two states that map to `.speaking` carry
    /// the higher energy, the two that do not carry the lower.
    func testOrbLevelDiffersAcrossTheModeBoundaryItIsReadAt() {
        for state in AgentState.allCases {
            let level = HomeView.orbLevel(for: state)
            let speaking = state.orbMode == .speaking
            XCTAssertEqual(
                level, speaking ? 0.7 : 0.2,
                "\(state) maps to \(state.orbMode); its level must follow that boundary"
            )
        }
        // The assertion above is satisfiable by a constant if every state
        // happened to share a mode. It does not — but that is a fact about
        // `orbMode`, not about this leg, so the leg states it itself.
        XCTAssertNotEqual(
            HomeView.orbLevel(for: .responding),
            HomeView.orbLevel(for: .ambient),
            "orbLevel must not collapse to a constant"
        )
    }

    /// `AgentState` is exhaustive and `CaseIterable`, so a fifth phase makes
    /// the `switch` in `orbLevel` fail to compile — the compiler holds
    /// totality. What it CANNOT hold is that a new phase gets a considered
    /// energy rather than being dropped into the default arm, so this leg
    /// pins the count the author reasoned over.
    func testOrbLevelIsTotalOverEveryAgentState() {
        XCTAssertEqual(AgentState.allCases.count, 4)
        let levels = Set(AgentState.allCases.map { HomeView.orbLevel(for: $0) })
        XCTAssertEqual(levels, [0.2, 0.7])
    }

    /// The orb announces the ORB's vocabulary (energy) and the grid announces
    /// the PHASE. Both are on this screen now, and this asserts they do not
    /// say the same thing — the split `AccessibilityTests:28-40` documents,
    /// enforced at the one screen where both surfaces are visible at once.
    ///
    /// `listening` and `responding` are the pair that proves it: they differ
    /// in the grid and are identical to the orb, by design.
    func testOrbValueAndGridBadgeAnswerDifferentQuestions() {
        let listening = AgentState.listening
        let responding = AgentState.responding

        XCTAssertEqual(
            DeviceOrb.accessibilityValue(for: listening.orbMode),
            DeviceOrb.accessibilityValue(for: responding.orbMode),
            "the orb speaks energy: both speaking phases are one value to it"
        )
        XCTAssertNotEqual(
            listening.badgeText, responding.badgeText,
            "the grid speaks phase: it must still tell them apart"
        )
    }

    // MARK: - The grid does not collapse two questions into one

    /// An idle agent behind an unreachable gateway is NOMINAL and REMOTE at
    /// once, both true. If a later refactor folds them into a single indicator
    /// it must pick one to hide, and this leg is what fails when it does.
    func testAgentPhaseAndLinkTopologyAreIndependentValues() {
        let agent = AgentState.ambient.badgeText
        let link = LinkState.unreachable(host: "zeus.local", reason: "timeout").badgeText
        XCTAssertEqual(agent, "NOMINAL")
        XCTAssertEqual(link, "REMOTE")
        XCTAssertNotEqual(agent, link)
    }
}
