# The "ten shippable sites" retract — f707091

RULING SHAPE: cut 10 of 17 `.system(size:` sites onto `Theme`, defer 3 glyphs, 4 DEBUG raw.
FINDING: the text-carrying set is **ZERO**. 17 = 4 DEBUG `Text` (OrbBench) + **13** `Image(systemName:)` glyphs.

Cause: the glyph census used `git grep "Image(systemName:.*\.system(size:"` — SAME-LINE only.
git grep is line-oriented; 10 of the 13 carry the Image on the PRECEDING line. Both seats ran
the same needle and both got 3. Fourth mode of the dead-probe family, receiver edition.

AST-free receiver walk (python, back to nearest non-blank non-comment line):
  Image receiver: Commissioning 154,215,376 · HomeView 178,331 · NodesView 215,255,277,306,353 · RootView 228,264 · SessionView 266  = 13
  Text receiver : OrbBench 125,129,133,137 (all inside #if DEBUG :118-:146) = 4
Fixed frame within 7 lines: Commissioning:154 · HomeView:331 · NodesView:277,:306,:353 · SessionView:266 = 6

CONSEQUENCE: cutting the ten would have applied the TEXT metric to 13 glyphs, six of them
inside pinned frames — manufacturing the exact clip class fa0809b/f103764 removed.
The whole 17 is now ONE deferred class: `.imageScale` + frame review. No commit cut.

## Correction 1 — the 4th DEBUG site is a `Button`, not "1 other"

`OrbBench.swift:137` receives `Button("RUN") { … }`. A string-label `Button`
renders a `Text`, so `.font` lands on the title exactly as the other three.
It read as "other" only because the walk stops at the SYNTACTIC receiver and
never asks what that receiver RENDERS. A receiver walk fixes line-orientation;
it does not fix indirection.

## Correction 2 — `.imageScale` is NOT a Dynamic Type fix (measured, iPhone 17 sim)

Measured off-render with `ImageRenderer` at scale 1, `Image(systemName:"checkmark")`,
`.environment(\.dynamicTypeSize, …)`, both categories in the SAME invocation:

    pinned  .font(.system(size: 15))                L=(17,15)   AX5=(17,15)    flat
    pinned  + .imageScale(.large)                   L=(20,20)   AX5=(20,20)    flat
    themed  .font(Theme.body(15))                   L=(17,15)   AX5=(17,15)    flat (see aperture)
    styled  .font(.body)                            L=(19,17)   AX5=(59,53)    3.1x   <- POS CTL

UIKit agrees: `UIImage.SymbolConfiguration(pointSize:)` is flat across
`large`/`AX5`; `(textStyle: .body)` goes (18.3,16.3) -> (58,51.7).

CONSEQUENCE: `.imageScale` is a fixed 3-step multiplier on the pinned point
size. It changes a glyph's size ONCE, at build time, and leaves it exactly as
unscaled at AX5 as it is today. The ruled shape — ".imageScale per site chosen
by role" — is a cosmetic re-size, not an accessibility repair, and it would
close the item while the defect it names remains at all 13 sites.

The only thing that makes an SF Symbol track Dynamic Type is a TEXT-STYLE font
(`.font(.body)`, or `Theme.body(N)` which is `.system(size: scaledSize(N, relativeTo:))`)
— which is precisely what the retract above rejected for the six sites inside
pinned frames, because a scaled child in a fixed parent is the clip class
`f103764`/`fa0809b` removed. So the two available moves are in genuine
opposition and neither is free:

    scale the glyph  -> it overflows the six pinned frames
    leave it pinned  -> it does not respond to Dynamic Type at all
    .imageScale      -> neither: a one-time re-size that fixes nothing

APERTURE: the `Theme.body(15)` row is flat in this harness, which is either
(a) `UIFontMetrics` ambient resolution not tracking the SwiftUI environment
inside `ImageRenderer`, or (b) the production behaviour. The POS control rules
out a dead harness — `.body` responds 3.1x in the same invocation — but it does
NOT discriminate (a) from (b), because `.body` is resolved by SwiftUI and
`Theme.body` by `UIFontMetrics.scaledValue(for:)` against
`UITraitCollection.current`. `Theme.scaledSize(15, .body, for: .accessibility5)`
= 42.3 vs 15.0 when told the category EXPLICITLY, so the metric itself works.
Settling (a)/(b) needs a device or a UI test, neither of which exists here.
