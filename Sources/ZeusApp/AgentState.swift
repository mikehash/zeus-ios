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
