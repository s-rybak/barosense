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

    /// `color/azure/15` (Mirage) — primary text, selected tab, accent button fill.
    static let ink = Color(hex: 0x1B2130)

    /// `color/orange/68` (Nomad) — unselected tab icon and label.
    static let inkMuted = Color(hex: 0xB7B2A6)

    /// `color/grey/94` (Pampas) — content drawn on top of `ink`.
    static let onInk = Color(hex: 0xF4F2ED)

    /// Drop shadow under the raised centre action: `rgba(27, 33, 48, 0.35)`.
    static let accentShadow = Color(hex: 0x1B2130).opacity(0.35)

    // MARK: - Onboarding (Figma `7:338`)

    /// `color/grey/10` (Woodsmoke) — headings.
    ///
    /// Not the same token as `ink`: the design sets headings a shade warmer and darker
    /// than the filled buttons and selected states around them.
    static let heading = Color(hex: 0x17181C)

    /// `color/grey/44` (Nevada) — body copy under a heading, and the label of an
    /// unselected choice.
    static let bodyText = Color(hex: 0x6B6F76)

    /// `color/orange/56` (Pale Oyster) — field placeholders, units, tertiary actions.
    static let placeholder = Color(hex: 0x9C9484)

    /// `color/orange/84` (Westar) — the border of an unselected field, chip or row, and
    /// an unfilled progress segment. A step darker than `separator`, which is the
    /// hairline between surfaces rather than the outline of a control.
    static let controlBorder = Color(hex: 0xDDD9D0)

    /// `color/white/solid` — fill of an unselected field, chip or row. Deliberately pure
    /// white against the warm `surface`, so a control reads as raised off the page.
    static let controlFill = Color.white

    /// `color/azure/19` (Ebony Clay) — a card on the dark closing screen.
    static let elevatedInk = Color(hex: 0x242B3D)

    /// `color/azure/66` (Gull Gray) — body copy on the dark closing screen.
    static let bodyTextOnInk = Color(hex: 0x9CA3B5)

    /// `color/spring-green/45` (Chateau Green) — the confirmation ring, and the marker on
    /// a row describing something already in place.
    static let positive = Color(hex: 0x3FA66B)

    /// `color/red/56` (Red Damask) — the Apple Health tile.
    static let health = Color(hex: 0xD65B4A)

    /// `color/red/61` (Burnt Sienna) — marker on the forecast row of the closing screen.
    static let markerWarm = Color(hex: 0xE8734F)

    /// `color/azure/56` (Royal Blue) — marker on the learning row of the closing screen.
    static let markerCool = Color(hex: 0x3E6BE0)
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
