import XCTest
import SwiftUI
@testable import Zeus

/// Test-only fixtures for `OrbStillness`.
///
/// They live HERE, not in production, deliberately. `OrbStillness` exists so
/// that dropping the reduce-motion read at `DeviceOrb.swift:105` is a compile
/// error rather than a silent green; a production-visible `.moving` would let
/// a call site write `stillness: .moving` and reinstate the exact mutant the
/// type was introduced to kill — same defect, new costume.
extension OrbStillness {
    /// Motion suppressed.
    static let still = OrbStillness(frozen: true, reduceMotion: false)
    /// Motion running.
    static let moving = OrbStillness(frozen: false, reduceMotion: false)
}

/// Accessibility floors for the orb and the session header.
///
/// PRE-REGISTERED SHAPE. The vacuous form of a reduce-motion test is "with the
/// setting on, the animation is off" — a property of the SWITCH, which passes
/// on a build that renders one identical picture for every mode, i.e. exactly
/// the failure the test exists to catch. The discriminating form asserts that
/// the STATE IS RECOVERABLE FROM A STILL RENDER: two modes, motion off, the
/// observable differs. That forces a second, non-motion channel to exist.
///
/// TWO INVARIANTS, NOT ONE, and they are deliberately different:
///
///   * ORB  -> `DeviceOrb.Mode` recoverable. THREE modes, energy. Its job is
///     that the still orb does not collapse to a single render.
///   * BADGE/HEADER -> `AgentState` recoverable. FOUR states, phase.
///
/// They cannot be merged. `AgentState.orbMode` maps four states onto three
/// modes — `listening` and `responding` are both `.speaking` — and
/// `AgentState.swift` documents that collapse as design: the orb distinguishes
/// energy, the badge distinguishes phase, and they are not the same alphabet.
/// An "AgentState recoverable from the orb" leg could only pass by breaking
/// that decision, so it is not a floor. Hence the split.
final class OrbReduceMotionTests: XCTestCase {

    /// Run one still frame for a mode and return the resulting state.
    ///
    /// Through `advance(stillness: .still)`, not by calling `snap` directly: the
    /// production path is what must be still-correct, and a helper that
    /// bypassed it would guard a function nothing renders.
    private func stillState(_ mode: DeviceOrb.Mode, level: Double = 0) -> OrbState {
        let sim = OrbSimulation()
        sim.advance(to: Date(), mode: mode, level: level, stillness: .still)
        return sim.state
    }

    // MARK: - The discriminating legs

    /// THE LEG. Three modes, motion off, all three renders differ.
    ///
    /// Asserted on the two terms mode actually reaches the renderer through —
    /// `glow` (which gates the energy arcs at `guard s.glow >= 0.5`) and
    /// `spikeIntensity` (surface displacement). Pairwise, not merely "not all
    /// equal": a build where two of three collapse is still a build where a
    /// user cannot tell those two apart.
    func testEveryModeRendersDifferentlyWithMotionOff() {
        let dormant = stillState(.dormant)
        let thinking = stillState(.thinking)
        let speaking = stillState(.speaking)

        XCTAssertNotEqual(dormant.glow, thinking.glow, accuracy: 0,
            "dormant and thinking must not render identically with motion off")
        XCTAssertNotEqual(thinking.glow, speaking.glow, accuracy: 0,
            "thinking and speaking must not render identically with motion off")
        XCTAssertNotEqual(dormant.glow, speaking.glow, accuracy: 0,
            "dormant and speaking must not render identically with motion off")

        XCTAssertNotEqual(dormant.spikeIntensity, speaking.spikeIntensity, accuracy: 0,
            "the second channel must carry more than one term")
    }

    /// The arc channel specifically — the one a frozen-at-defaults build loses.
    ///
    /// Arcs are gated by `glow >= 0.5`. Default glow is 0.4, so a build that
    /// merely holds the clock draws ZERO arcs in every mode and this leg goes
    /// red. It is the direct guard on snap-vs-freeze.
    func testStillOrbCrossesTheArcThresholdWhereTheAnimatedOneWould() {
        XCTAssertLessThan(stillState(.dormant).glow, 0.5,
            "dormant must stay below the arc threshold — 0 arcs is its signature")
        XCTAssertGreaterThanOrEqual(stillState(.thinking).glow, 0.5,
            "thinking must draw arcs when still; frozen-at-defaults (0.4) would not")
        XCTAssertGreaterThanOrEqual(stillState(.speaking).glow, 0.5,
            "speaking must draw arcs when still")
    }

    /// `speakWave` is the other mode-carrying term and it is 0 by default, so a
    /// frozen-at-defaults speaking orb loses its surface displacement entirely
    /// (`speakNoise` is scaled by `speakWave * 0.4 + level * 0.5`, and OrbGlyph
    /// passes no level — both terms zero).
    func testSpeakingKeepsItsSurfaceDisplacementWhenStill() {
        XCTAssertGreaterThan(stillState(.speaking).speakWave, 0,
            "a still speaking orb with speakWave 0 has no displacement channel at all")
        XCTAssertEqual(stillState(.thinking).speakWave, 0, accuracy: 0,
            "only speaking carries the wave — a non-zero here would erase the distinction")
    }

    // MARK: - Vacuity floors

    /// VACUITY FLOOR. The assertions above are all NEGATIVE (states differ);
    /// they would every one of them pass on a simulation that produced garbage,
    /// or that never ran. This pins the still render to the ACTUAL targets, so
    /// nobody can read the differences as incidental.
    func testStillRenderSitsExactlyOnTheModeTargets() {
        for mode in [DeviceOrb.Mode.dormant, .thinking, .speaking, .rage] {
            let s = stillState(mode)
            let t = OrbModeTargets.targets(for: mode)
            XCTAssertEqual(s.glow, t.glow, accuracy: 0.0001,
                "\(mode) still glow must BE the target, not merely differ from its siblings")
            XCTAssertEqual(s.spikeIntensity, t.spikeIntensity, accuracy: 0.0001)
            XCTAssertEqual(s.rotation, t.rotation, accuracy: 0.0001)
            XCTAssertEqual(s.mode, mode)
        }
    }

    /// VACUITY FLOOR. Proves the still arm is not simply the animated arm under
    /// another name — a `snap` that did nothing and an `advance` that ran would
    /// both satisfy "the state has the right mode". One tick of the animated
    /// path lerps 6% of the way; the still path arrives.
    func testOneAnimatedTickDoesNotReachTheTargetButTheStillFrameDoes() {
        let animated = OrbSimulation()
        animated.advance(to: Date(), mode: .speaking, level: 0, stillness: .moving)

        let t = OrbModeTargets.targets(for: .speaking)
        XCTAssertNotEqual(animated.state.glow, t.glow, accuracy: 0.01,
            "VACUITY FLOOR: one animated tick must NOT arrive, or the two arms are the same code")
        XCTAssertEqual(stillState(.speaking).glow, t.glow, accuracy: 0.0001,
            "the still arm must arrive in one step")
    }

    /// The still arm must be IDEMPOTENT and clock-free: repeated frames of a
    /// motionless orb must not drift, or "still" is just "slow".
    func testStillFramesDoNotDrift() {
        let sim = OrbSimulation()
        sim.advance(to: Date(), mode: .thinking, level: 0, stillness: .still)
        let first = sim.state
        for i in 1...10 {
            sim.advance(to: Date().addingTimeInterval(Double(i)), mode: .thinking,
                        level: 0, stillness: .still)
        }
        XCTAssertEqual(sim.state.glow, first.glow, accuracy: 0)
        XCTAssertEqual(sim.state.time, first.time, accuracy: 0,
            "the clock must not advance while still")
    }

    /// A mode CHANGE while still must be honoured. Without this, an orb that
    /// snapped once at seed and then ignored the mode would pass every leg
    /// above — each of them builds a fresh simulation.
    func testModeChangeIsHonouredWithoutMotion() {
        let sim = OrbSimulation()
        sim.advance(to: Date(), mode: .dormant, level: 0, stillness: .still)
        let before = sim.state.glow
        sim.advance(to: Date().addingTimeInterval(1), mode: .speaking, level: 0, stillness: .still)
        XCTAssertNotEqual(sim.state.glow, before, accuracy: 0,
            "a still orb must still TRACK the agent — one simulation, two modes")
        XCTAssertEqual(sim.state.glow, OrbModeTargets.targets(for: .speaking).glow,
                       accuracy: 0.0001)
    }
}

/// VoiceOver labels. Same trap as reduce-motion: a label pinned on ONE state
/// passes any single-state test, so the legs assert the label CHANGES across
/// states.
final class OrbVoiceOverTests: XCTestCase {

    func testEveryOrbModeHasADistinctSpokenValue() {
        let values = DeviceOrb.Mode.allCases.map { DeviceOrb.accessibilityValue(for: $0) }
        XCTAssertEqual(Set(values).count, DeviceOrb.Mode.allCases.count,
            "a label that does not change across modes announces a decorative shape")
    }

    /// The spoken value must name the ACTIVITY, not the renderer's vocabulary.
    /// `mode.rawValue` would satisfy the distinctness leg above while telling a
    /// screen-reader user what the picture looks like.
    ///
    /// ASSERTED PER-MODE AND NOT UNIVERSALLY, because the first draft of this
    /// leg was WRONG and the suite caught it: it demanded every spoken value
    /// differ from its `rawValue`, and went red on `.thinking`, whose renderer
    /// name and activity name genuinely coincide. That is a real coincidence,
    /// not a defect — "thinking" IS what the agent is doing — and a leg that
    /// forces a worse word to satisfy a rule is a rule measuring the wrong
    /// thing. The three modes named below are the ones whose renderer names are
    /// pure shape-energy words with no activity meaning; those are the ones a
    /// screen reader must never hear.
    func testSpokenValueIsNotTheRendererVocabulary() {
        for mode in [DeviceOrb.Mode.dormant, .speaking, .rage] {
            XCTAssertNotEqual(DeviceOrb.accessibilityValue(for: mode), mode.rawValue,
                "\(mode): announcing the renderer's own enum name describes the shape, not the agent")
        }
        // VACUITY FLOOR for the exemption: `.thinking` is exempted because the
        // words coincide, NOT because the mapping may be identity there. Pin
        // the value, so the exemption cannot widen into a hole.
        XCTAssertEqual(DeviceOrb.accessibilityValue(for: .thinking), "thinking")
    }

    /// PHASE, four states — the invariant the orb structurally cannot carry.
    func testHeaderLabelDiffersAcrossAllFourAgentStates() {
        let labels = AgentState.allCases.map {
            SessionView.headerAccessibilityLabel(sessionID: "abc123de-ffff",
                                                 status: "LINKED", state: $0)
        }
        XCTAssertEqual(Set(labels).count, AgentState.allCases.count,
            "AgentState must be recoverable from the header a screen reader hears")
    }

    /// The header must carry BOTH facts. Phase and topology answer different
    /// questions and a label with only one of them is a collapse.
    func testHeaderLabelCarriesPhaseAndTopologyTogether() {
        let label = SessionView.headerAccessibilityLabel(
            sessionID: "abc123de-ffff", status: "UNREACHABLE", state: .ambient)
        XCTAssertTrue(label.contains("UNREACHABLE"), "topology missing: \(label)")
        XCTAssertTrue(label.contains(AgentState.ambient.badgeText), "phase missing: \(label)")
    }

    /// The em-dash absence must not be spoken as a dash. VoiceOver reads "—"
    /// unpredictably, and "SESSION dash" is worse than saying the thing.
    func testUnassignedSessionIsSpokenAsWordsNotPunctuation() {
        let label = SessionView.headerAccessibilityLabel(
            sessionID: nil, status: "LINKED", state: .ambient)
        XCTAssertFalse(label.contains("—"), "raw em-dash reaches the screen reader: \(label)")
        XCTAssertFalse(label.contains("·"), "raw separator reaches the screen reader: \(label)")
        XCTAssertTrue(label.contains("not yet assigned"), label)
    }
}

// MARK: - Dynamic Type
//
// PRE-REGISTERED SHAPE, and it is the reason `Theme.scaledSize` exists as a
// standalone function. The vacuous form here is "the label must not truncate
// at the largest accessibility size" — which passed at f4e8152 for the reason
// that made it worthless: all three type families terminated in a bare
// `Font.system(size:)`, a FIXED-POINT font, so every string rendered at one
// point size from xSmall to AX5 and no string was long enough to fail. A
// no-truncation leg on that tree is a claim about a build that ignores the
// setting, the same shape as "with reduce-motion on, the animation is off".
//
// So THE SUBJECT IS SCALING, NOT FITTING, in two clauses where the first is
// the second's vacuity floor:
//
//   1. the derived metric DIFFERS across two `dynamicTypeSize` values
//   2. the larger one is the larger  (ordering, not just inequality)
//
// Clause 1 is RED at f4e8152 by construction — nothing there varies with the
// category — and GREEN the moment Theme scales. Nothing deliberate about it.
final class DynamicTypeTests: XCTestCase {

    /// VACUITY FLOOR for every assertion below it: the derivation must RESPOND
    /// to the category at all. A pinned subject makes a live positive control
    /// and a dead one the same object, so this clause has to come first.
    func testScaledSizeRespondsToTheContentSizeCategory() {
        let small = Theme.scaledSize(9, relativeTo: .caption, for: .xSmall)
        let ax5 = Theme.scaledSize(9, relativeTo: .caption, for: .accessibility5)
        XCTAssertNotEqual(small, ax5,
            "VACUITY FLOOR: the type does not scale — every leg below is vacuous")
        XCTAssertGreaterThan(ax5, small,
            "AX5 must be LARGER, not merely different: \(small) -> \(ax5)")
    }

    /// The floor above proves motion on ONE size pair. This proves the
    /// derivation is monotone across the whole ladder — a function that jumped
    /// at one boundary and was flat elsewhere would satisfy the floor.
    func testScaledSizeIsMonotoneAcrossTheWholeLadder() {
        let ladder: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
            .accessibility1, .accessibility2, .accessibility3,
            .accessibility4, .accessibility5,
        ]
        let sizes = ladder.map { Theme.scaledSize(11, relativeTo: .body, for: $0) }
        for (i, pair) in zip(sizes, sizes.dropFirst()).enumerated() {
            XCTAssertLessThanOrEqual(pair.0, pair.1,
                "not monotone at \(ladder[i]) -> \(ladder[i + 1]): \(pair.0) -> \(pair.1)")
        }
        XCTAssertGreaterThan(sizes.last!, sizes.first!,
            "VACUITY FLOOR: a constant function is monotone — the ladder must actually rise")
    }

    /// The three families are the ONLY way type reaches the screen, so the
    /// derivation being live is worth nothing unless they call it. A family
    /// that kept a bare `Font.system(size:)` would pass every leg above.
    ///
    /// A `Font` is opaque and its resolved size is not readable, so the
    /// assertion is on the derivation the family is REQUIRED to route through:
    /// the family's declared text style must scale. If a family were rewired to
    /// a fixed size, its style's derivation is the thing this pins.
    func testEveryFamilyDeclaresAStyleThatScales() {
        for style in [Font.TextStyle.headline, .body, .caption] {
            let small = Theme.scaledSize(12, relativeTo: style, for: .xSmall)
            let ax5 = Theme.scaledSize(12, relativeTo: style, for: .accessibility5)
            XCTAssertGreaterThan(ax5, small, "family style \(style) does not scale")
        }
    }

    /// The UIKit bridge is where a silent wrong answer lives: `@unknown default`
    /// absorbing a real style into `.body` gives a plausible number with the
    /// wrong scale factor. Distinctness is the cheap proof the map is injective
    /// on the arms we use.
    func testTextStyleBridgeIsInjectiveOnTheStylesWeUse() {
        let mapped = [Font.TextStyle.largeTitle, .title, .title2, .title3,
                      .headline, .subheadline, .body, .callout, .footnote,
                      .caption, .caption2].map(Theme.uiTextStyle)
        XCTAssertEqual(Set(mapped).count, mapped.count,
            "two SwiftUI styles collapsed onto one UIKit style: \(mapped)")
    }

    /// Same argument on the category ladder: a collapse here reads as "AX4 and
    /// AX5 happen to render the same", which is indistinguishable from a
    /// platform clamp unless the map is known to be injective.
    ///
    /// Same scope caveat as the style bridge: the ENUMERATED ladder only. The
    /// `@unknown default` arm is unreachable from here.
    func testContentSizeCategoryBridgeIsInjective() {
        let ladder: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
            .accessibility1, .accessibility2, .accessibility3,
            .accessibility4, .accessibility5,
        ]
        let mapped = ladder.map(Theme.uiContentSizeCategory)
        XCTAssertEqual(Set(mapped).count, mapped.count,
            "two DynamicTypeSize values collapsed onto one category: \(mapped)")
    }

    /// The badge is the surface that carries PHASE (the four-state invariant
    /// above), and it sits in a header that is now one combined VoiceOver
    /// element — so a badge that outgrows its row costs the phase surface.
    /// 8.5pt at AX5 must still be a sane label size, not a headline.
    func testBadgeStaysProportionateAtTheLargestSize() {
        let badge = Theme.scaledSize(8.5, relativeTo: .caption, for: .accessibility5)
        let body = Theme.scaledSize(17, relativeTo: .body, for: .accessibility5)
        XCTAssertLessThan(badge, body,
            "the badge outgrew body copy at AX5: \(badge) vs \(body)")
        XCTAssertGreaterThan(badge, 8.5,
            "VACUITY FLOOR: the badge did not scale at all")
    }
}
