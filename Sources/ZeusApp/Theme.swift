import SwiftUI
import UIKit

/// Igneous Precision — design tokens for the Zeus operator app.
///
/// Every value here is transcribed from the landed prototype at the canonical
/// git ref `817b19d3d:docs/prototypes/mobile/zeus/ZeusApp.jsx` (925 lines)
/// (hex literals :302-303 and the palette block :26).
///
/// The ref form is deliberate: a worktree path names bytes that can move or be
/// archived, and a provenance line pointing into a purge candidate dies with it,
/// taking the reason along. `git show <ref>` reproduces the subject from the
/// object store for as long as the commit is reachable. It is a TRANSCRIPTION,
/// not a derivation — if the prototype moves, this file does not follow it
/// automatically and the two will drift silently. The prototype is the
/// authority; this is a copy with a known origin.
enum Theme {

    // MARK: - Palette
    //
    // Frequency in the source (`grep -oE '#[0-9a-fA-F]{6}'`, 925 lines):
    // f5ede8 x14 · 3adf7c x7 · 180400 x4 · ffd24a x3 · ff4d4d x3 · c92808 x3

    /// Primary accent. `ACC` at ZeusApp.jsx:302.
    static let accent = Color(hex: 0xFF5028)
    /// Secondary accent — icons, status text. `ACC2` at :303.
    static let accent2 = Color(hex: 0xFF7838)
    /// Gradient shoulder, paired with `accent` on buttons (:918).
    static let accentDeep = Color(hex: 0xC92808)

    /// Page background — the darkest of the three browns.
    static let bg = Color(hex: 0x0D0806)
    /// Raised surface (cards, bars).
    static let surface = Color(hex: 0x140805)
    /// Ink on an accent fill — the button glyph color at :915/:919.
    static let onAccent = Color(hex: 0x180400)

    /// Primary text. The most frequent literal in the source.
    static let text = Color(hex: 0xF5EDE8)

    static let ok = Color(hex: 0x3ADF7C)
    static let warn = Color(hex: 0xFFD24A)
    static let danger = Color(hex: 0xFF4D4D)
    static let info = Color(hex: 0x4AA8FF)

    /// Warm white at partial opacity — the prototype's `w(a)` helper.
    static func w(_ a: Double) -> Color { text.opacity(a) }
    /// Accent at partial opacity — the prototype's `r(a)` helper.
    static func r(_ a: Double) -> Color { accent.opacity(a) }

    /// `linear-gradient(160deg, ${ACC}, #c92808)` — the prototype's action
    /// button fill, used at every send/mic/primary site (:659, :664).
    /// 160deg in CSS is measured clockwise from "to top", which puts the
    /// start point near top-leading and the end near bottom-trailing.
    static let accentGradient = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .init(x: 0.32, y: 0.0),
        endPoint: .init(x: 0.68, y: 1.0)
    )

    // MARK: - Type
    //
    // The prototype names three families (:299-301): Orbitron (display),
    // Rajdhani (body), JetBrains Mono (data/meta).
    //
    // NONE OF THE THREE ARE PRESENT IN THIS TREE and none ship with iOS.
    // Until the TTFs are vendored and registered in Info.plist
    // (UIAppFonts), these resolve to system substitutes. That is a KNOWN
    // AND DELIBERATE GAP, not a styling choice — `display` is rounded
    // rather than Orbitron, and it will look wrong beside the prototype.
    // Fixing it is a separate cut: add the files, add UIAppFonts, then
    // swap the three `Font.system` calls below for `Font.custom`.
    //
    // SCALING IS A SEPARATE AXIS FROM TYPEFACE, and the block above is
    // ONLY about typeface. Until this cut, all three families terminated
    // in a bare `Font.system(size:)` — a FIXED-POINT font that does not
    // respond to the accessibility text-size setting at all. Every type
    // site in the app rendered identically at xSmall and at AX5, so
    // "the label must not truncate at the largest size" was vacuously
    // true: there was no largest size. The three families now route
    // through `scaledSize` below, which is the whole of the scaling
    // behaviour and the only thing a test can interrogate.

    /// The Dynamic Type derivation, lifted OUT of the font constructors so it
    /// is assertable.
    ///
    /// A SwiftUI `Font` is opaque: there is no `scaledValue` readable off
    /// `Theme.mono(9)`, and the size it resolves to is observable only in a
    /// render — which a `bundle.unit-test` target cannot perform. The same
    /// shape as `accessibilityValue`: what is derived INSIDE a `body` is
    /// guardable only by screenshot. So the derivation is a pure function of
    /// (size, style, category) and the families call it. A leg asserting on
    /// this function is asserting on the thing that actually scales the text,
    /// not on a parallel copy of it.
    ///
    /// - Parameter dynamicTypeSize: `nil` means "resolve against the ambient
    ///   trait collection", which is what production wants — SwiftUI sets
    ///   `UITraitCollection.current` while evaluating a `body`. Tests pass an
    ///   explicit category so the function is deterministic off-render.
    static func scaledSize(_ size: CGFloat,
                           relativeTo style: Font.TextStyle = .body,
                           for dynamicTypeSize: DynamicTypeSize? = nil) -> CGFloat {
        let metrics = UIFontMetrics(forTextStyle: uiTextStyle(style))
        guard let dynamicTypeSize else { return metrics.scaledValue(for: size) }
        return metrics.scaledValue(
            for: size,
            compatibleWith: UITraitCollection(
                preferredContentSizeCategory: uiContentSizeCategory(dynamicTypeSize)))
    }

    /// Wordmark, badges, tab labels. Orbitron when vendored.
    static func display(_ size: CGFloat,
                        _ weight: Font.Weight = .semibold,
                        relativeTo style: Font.TextStyle = .headline) -> Font {
        .system(size: scaledSize(size, relativeTo: style), weight: weight, design: .rounded)
    }

    /// Body copy. Rajdhani when vendored.
    static func body(_ size: CGFloat,
                     _ weight: Font.Weight = .regular,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: scaledSize(size, relativeTo: style), weight: weight, design: .default)
    }

    /// Data, meta, status lines. JetBrains Mono when vendored.
    static func mono(_ size: CGFloat,
                     _ weight: Font.Weight = .regular,
                     relativeTo style: Font.TextStyle = .caption) -> Font {
        .system(size: scaledSize(size, relativeTo: style), weight: weight, design: .monospaced)
    }

    // The two bridges below exist because `UIFontMetrics` is the only pure,
    // off-render Dynamic Type calculator on the platform and it speaks UIKit.
    //
    // Both are written out case by case rather than with a `default` arm, so
    // that a future SwiftUI text style or size class is a COMPILER WARNING here
    // instead of arriving silently. The `@unknown default` arms then decide
    // what happens if that warning is ever ignored, and the choice is ABSORB —
    // fall back to `.body` / `.large` — not `fatalError`.
    //
    // The trade, deliberately: absorbing is WASTEFUL, trapping is FATAL. A
    // future OS's new style routed through `.body` gives one string a wrong
    // scale factor, and no user can tell. A `fatalError` on that same arm is a
    // crash on an OS version nobody on this project can test against, on the
    // user's device, for a cosmetic miss. Same trade taken at `paused:` in
    // `DeviceOrb`: wrong there is wasteful, not wrong.
    //
    // This is a product call, not a measurement. It is revisitable the day
    // there is CI gating warnings on this repo — until then the warning is a
    // comment, and these arms are what actually stands behind it.

    static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle:  return .largeTitle
        case .title:       return .title1
        case .title2:      return .title2
        case .title3:      return .title3
        case .headline:    return .headline
        case .subheadline: return .subheadline
        case .body:        return .body
        case .callout:     return .callout
        case .footnote:    return .footnote
        case .caption:     return .caption1
        case .caption2:    return .caption2
        @unknown default:  return .body
        }
    }

    static func uiContentSizeCategory(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall:               return .extraSmall
        case .small:                return .small
        case .medium:               return .medium
        case .large:                return .large
        case .xLarge:               return .extraLarge
        case .xxLarge:              return .extraExtraLarge
        case .xxxLarge:             return .extraExtraExtraLarge
        case .accessibility1:       return .accessibilityMedium
        case .accessibility2:       return .accessibilityLarge
        case .accessibility3:       return .accessibilityExtraLarge
        case .accessibility4:       return .accessibilityExtraExtraLarge
        case .accessibility5:       return .accessibilityExtraExtraExtraLarge
        @unknown default:           return .large
        }
    }

    /// Line limits are a CLIP BUDGET, and a budget calibrated at default size
    /// is wrong once the type scales: the same string needs more lines at AX5,
    /// so a fixed `lineLimit(2)` starts losing words at exactly the size the
    /// setting was turned up to avoid squinting at them.
    ///
    /// Takes a `Bool`, not a `DynamicTypeSize`, on purpose — this needs no
    /// third bridge, so it cannot acquire an `@unknown default` arm of its own.
    static func lineLimit(_ base: Int, accessibilitySize: Bool) -> Int {
        accessibilitySize ? base * 2 : base
    }

    // MARK: - Metrics
    // Transcribed from the prototype's button/bar geometry (:911-919).

    static let controlSize: CGFloat = 44
    static let corner: CGFloat = 10
    static let barCorner: CGFloat = 6
    static let hairline: CGFloat = 1

    /// The display tracking the prototype applies to tab and badge labels.
    static let displayTracking: CGFloat = 1.2
}

extension Color {
    /// 0xRRGGBB — the form the prototype's literals are already in, so the
    /// transcription is a copy rather than a conversion.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >>  8) & 0xFF) / 255.0,
            blue:  Double( hex        & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
