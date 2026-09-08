import SwiftUI

/// The agent's four presentational states.
///
/// Transcribed from `docs/prototypes/mobile/zeus/ZeusApp.jsx` at
/// `origin/main` = 817b19d3d. The set is EXHAUSTIVE over that file by two
/// independent counts taken at the same ref:
///
///   * `BADGES` (:333-338) declares exactly 4 keys
///   * `grep -oE "setAgentState\('[a-z]+'\)" | sort -u` returns exactly the
///     same 4 identifiers — ambient, listening, responding, thinking
///
/// Two counts because one is the LOOKUP TABLE and the other is the set of
/// values actually WRITTEN; a state present in one and absent from the other
/// would be a defect in the prototype, and agreement is what makes this an
/// exhaustive enum rather than a prefix.
///
/// Being an enum means a fifth state cannot be introduced without every
/// `switch` over it failing to compile — the compiler holds the invariant
/// instead of a comment.
enum AgentState: String, CaseIterable, Identifiable {
    case ambient
    case listening
    case thinking
    case responding

    var id: String { rawValue }

    /// Badge caption. `BADGES[state].text` at :333-338.
    var badgeText: String {
        switch self {
        case .ambient:    return "NOMINAL"
        case .listening:  return "RECEIVING"
        case .thinking:   return "REASONING"
        case .responding: return "STREAMING"
        }
    }

    /// The orb mode this agent state drives. `orbMode` at :473-475.
    ///
    /// FOUR STATES MAP ONTO THREE MODES — `listening` and `responding` both
    /// render as `speaking`. That collapse is in the prototype and is kept
    /// rather than "corrected": the orb distinguishes *energy*, the badge
    /// distinguishes *phase*, and they are deliberately not the same alphabet.
    ///
    /// Note what is NOT reachable through here: `DeviceOrb.Mode.rage` has no
    /// agent state that produces it. Since `AgentState` is exhaustive and this
    /// switch is total over it, `rage` is provably unreachable from the app's
    /// own state machine — which is PROTOTYPE-AUDIT.md defect ③ stated as a
    /// property of the code instead of a remark about it.
    var orbMode: DeviceOrb.Mode {
        switch self {
        case .listening, .responding: return .speaking
        case .thinking:               return .thinking
        case .ambient:                return .dormant
        }
    }

    /// Badge colour. `BADGES[state].color` at :333-338, resolving the
    /// prototype's GRN/ACC2/YLW/BLU constants declared at :302-304.
    var badgeColor: Color {
        switch self {
        case .ambient:    return Theme.ok        // GRN  #3adf7c
        case .listening:  return Theme.accent2   // ACC2 #ff7838
        case .thinking:   return Theme.warn      // YLW  #ffd24a
        case .responding: return Theme.info      // BLU  #4aa8ff
        }
    }
}

/// What the badge says once READINESS is taken into account, as ONE PAIR.
///
/// ## The defect this exists for
///
/// Three surfaces rendered `session.state` directly — the home `AGENT` tile
/// (`HomeView:188`), the session header pill (`SessionView:208`) and the
/// screen-reader label (`SessionView:219`). `AgentState` is a description of
/// the ENGINE's phase, and an idle engine is `.ambient` whether or not the
/// core has a provider. So a fresh install rendered `AGENT · NOMINAL` in
/// green, above a composer that could not send. Every value was true; the
/// composition was a lie, because the surface answers "are we ok" and the
/// value answers "is the engine busy."
///
/// ## Why a PAIR and not two functions
///
/// Text and tint must be derived in ONE place. Two accessors over the same
/// inputs can disagree — a later edit to a colour switch that forgets the
/// unarmed arm renders the word `UNARMED` in `ok` green, which is a worse
/// state than the one this replaces because it looks deliberate. Returning
/// the pair makes disagreement unrepresentable rather than merely unlikely.
///
/// ## Unarmed OVERRIDES the phase, and that is the whole claim
///
/// When there is no route to a model, the phase is not wrong — it is not
/// ANSWERING THE QUESTION. So the unarmed arm ignores `phase` entirely and
/// collapses all four states onto one badge. The injectivity leg over
/// `AgentState` is therefore two-armed: armed → `allCases.count` distinct,
/// unarmed → exactly 1.
struct ReadinessBadge: Equatable {
    let text: String
    let tint: Color

    /// `disarmReason == nil` is the readiness input, not a second predicate.
    ///
    /// It is deliberately the SAME value the composer gates on
    /// (`SessionView.canSend`) rather than a parallel readiness check: a badge
    /// derived from one source and a composer gated on another is exactly the
    /// disagreement this file exists to retire. One source, two readers.
    static func forState(_ phase: AgentState, disarmReason: String?) -> ReadinessBadge {
        guard disarmReason == nil else {
            return ReadinessBadge(text: "UNARMED", tint: Theme.unarmedTint)
        }
        return ReadinessBadge(text: phase.badgeText, tint: phase.badgeColor)
    }
}

/// The prototype's `Badge` component, :341-346.
///
/// The two alpha suffixes in the source are hex byte literals appended to a
/// 6-digit colour: `${color}55` border and `${color}14` background. 0x55/255
/// and 0x14/255 are carried through as opacities rather than re-picked by
/// eye — the transcription is a conversion of a stated value, not a guess.
struct Badge: View {
    let text: String
    let color: Color

    static let borderOpacity: Double = Double(0x55) / 255.0  // 0.333
    static let fillOpacity:   Double = Double(0x14) / 255.0  // 0.078

    var body: some View {
        Text(text)
            .font(Theme.display(8.5, .bold))
            .tracking(2.55)                                   // 0.3em at 8.5pt
            .foregroundStyle(color)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.top, 4)
            .padding(.bottom, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(Self.fillOpacity))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(color.opacity(Self.borderOpacity),
                                    lineWidth: Theme.hairline)
                    )
            )
    }
}
