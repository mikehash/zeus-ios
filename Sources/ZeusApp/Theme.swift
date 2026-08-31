import SwiftUI

/// Igneous Precision — design tokens for the Zeus operator app.
///
/// Every value here is transcribed from the landed prototype
/// `~/Zeus docs/prototypes/mobile/zeus/ZeusApp.jsx` at ref `817b19d3d`
/// (hex literals :302-303 and the palette block :26). It is a TRANSCRIPTION,
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

    /// Wordmark, badges, tab labels. Orbitron when vendored.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Body copy. Rajdhani when vendored.
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Data, meta, status lines. JetBrains Mono when vendored.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
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
