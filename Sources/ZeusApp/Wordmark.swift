import SwiftUI

/// The footer wordmark, one definition.
///
/// WHY A VIEW AND NOT A PIN, AND NOT A MIGRATION IN PLACE.
///
/// Arc D moved three rows out of `NodesView` into `SettingsView`, and the
/// footer strip came along by hand — the second screen was built with the
/// first one's footer copied into it. `check_separator_debt.sh` caught the
/// new `·` site, and the guard is correct to have caught it, but the debt
/// it named is the SMALLER half of the defect. Three repairs were available:
///
///   1. PIN the new site. Cheapest, and it writes the duplication down as
///      permanent: two literals, two fonts, two trackings, two paddings,
///      drifting independently forever. The pin would then be GREEN on a
///      tree where one footer says `ZEUS · NOVAXAI` and the other says
///      something else — a guard certifying the divergence it was built to
///      see. That is the swap-blindness the set-pin was written to fix,
///      re-introduced one layer up.
///
///   2. MIGRATE IN PLACE — `Theme.joined(["ZEUS", "NOVAXAI"])` at both
///      sites. Pays the separator debt, leaves the duplication: same two
///      copies of the font/tracking/opacity/padding block, now both correct.
///      The NEXT screen copies one of them and we are here again.
///
///   3. EXTRACT (this). One literal, one `Theme.joined` call, one metrics
///      block, two call sites. The separator debt goes to ZERO for this
///      text because there is only one text, and the pinned set SHRINKS by
///      one — an explicit lowering, which is the form the guard asks for.
///
/// The extraction is what the Arc-B lesson says to do on the addition side
/// and the Arc-D orphan finding says to do on the subtraction side: a second
/// copy inherits no guard, and a guard left pointing at a copy measures a
/// screen that may no longer do the thing.
///
/// METRICS PROVENANCE: 8.5pt mono, tracking 1.19 (0.14em at 8.5pt), white at
/// 0.2, 18/8 padding — transcribed from `NodesView`'s footer, which is the
/// prototype's. Both call sites rendered these values identically before the
/// extraction; `WordmarkTests` asserts the text, and the fact that there is
/// exactly one construction site is what keeps the metrics single-valued.
struct Wordmark: View {

    /// The rendered text, exposed so a test can assert it without a host.
    ///
    /// `Theme.joined` rather than a bare `·` literal: the two components are
    /// an identity strip like every other one in the app, and the footer is
    /// the LAST line on a 390pt screen — the wrap that strands the dot is
    /// exactly as available here as it was on the phone row.
    static let text = Theme.joined(["ZEUS", "NOVAXAI"])

    var body: some View {
        Text(Self.text)
            .font(Theme.mono(8.5))
            .tracking(1.19)                       // 0.14em at 8.5pt
            .foregroundStyle(Theme.w(0.2))
            .padding(.top, 18)
            .padding(.bottom, 8)
    }
}
