import SwiftUI

/// Colour tokens from the Barosense Figma library.
///
/// Names mirror the Figma variable names so a design change traces to one constant here.
/// Raw hex appears only in this file — nowhere else in the iOS target.
///
/// The design is a single warm light theme; there is no dark variant in Figma yet, so the
/// root view pins the app to the light scheme rather than letting the system invert
/// half of these.
enum Palette {

    /// `color/grey/96` (Spring Wood) — app background and tab-bar surface.
    static let surface = Color(hex: 0xF7F5F1)

    /// `color/orange/86` (Satin Linen) — hairline separators.
    static let separator = Color(hex: 0xE3DFD5)

    /// `color/white/solid` — fill of a card raised off `surface`.
    static let cardSurface = Color(hex: 0xFFFFFF)

    /// The 1 pt outline of a card. The same Figma token as `separator`, aliased rather
    /// than re-declared: one token, one hex, and a change to it moves both.
    static let cardBorder = separator

    /// `color/azure/15` (Mirage) — primary text, selected tab, accent button fill.
    static let ink = Color(hex: 0x1B2130)

    /// `color/grey/10` (Woodsmoke) — the numeral on a metric card.
    ///
    /// A separate token from `ink`, not a rounding of it: the design uses this one for
    /// figures on white and `ink` for chrome on `surface`.
    static let inkStrong = Color(hex: 0x17181C)

    /// `color/orange/68` (Nomad) — unselected tab icon and label.
    static let inkMuted = Color(hex: 0xB7B2A6)

    /// `color/orange/56` (Pale Oyster) — the caption under a metric card's figure.
    /// Darker than `inkMuted`, which sits on `surface` rather than on white.
    static let inkSubtle = Color(hex: 0x9C9484)

    /// `color/grey/94` (Pampas) — content drawn on top of `ink`.
    static let onInk = Color(hex: 0xF4F2ED)

    /// Drop shadow under the raised centre action: `rgba(27, 33, 48, 0.35)`.
    static let accentShadow = Color(hex: 0x1B2130).opacity(0.35)
}

extension Color {
    /// Builds a colour from a `0xRRGGBB` literal in the sRGB space.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
