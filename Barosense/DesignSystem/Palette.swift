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

    // MARK: - Pressure chart (Figma `7:671`)

    /// `color/azure/56` (Royal Blue) — the pressure line.
    ///
    /// The same Figma token as `markerCool`, aliased rather than re-declared: one token, one
    /// hex. Named for its role here because a chart series and a list marker move for
    /// different reasons.
    static let chartLine = markerCool

    /// `color/grey/93` (Pampas) — the track behind the range selector.
    ///
    /// Not `onInk` (`#F4F2ED`), which the design library also calls Pampas: they are two
    /// distinct values a shade apart, and using one for the other leaves the selector's
    /// white pill barely visible against its own track.
    static let segmentedTrack = Color(hex: 0xF0EEE8)

    // MARK: - Check-in intensity (Figma `7:330`)

    /// The ramp the intensity scale runs along, low to high: green at 1, red at 10.
    ///
    /// Five evenly spaced stops. The two ends and the fourth are existing Figma tokens
    /// (`positive`, `markerWarm`, `health`); the second and third are **not** in the design
    /// library reachable from this repo, which has no amber and no mid-green. They are chosen
    /// to keep the ramp monotone in both hue and lightness so it degrades to a usable
    /// greyscale gradient. Replace them with real tokens when they exist — this array is the
    /// only place either value is written.
    ///
    /// Hex rather than `Color` so a value between two stops can be mixed component-wise;
    /// `Color` has no portable way back out to its components.
    private static let intensityRamp: [UInt32] = [
        0x3FA66B, // `color/spring-green/45` (Chateau Green) — aliases `positive`
        0x84B85A, // not a Figma token
        0xE3A93F, // not a Figma token
        0xE8734F, // `color/red/61` (Burnt Sienna) — aliases `markerWarm`
        0xD65B4A  // `color/red/56` (Red Damask) — aliases `health`
    ]

    /// The colour of one point on the 1–10 check-in scale — what the slider's thumb sits on
    /// in the Log sheet, and the colour that check-in's dot takes on the pressure chart. One
    /// mapping, so the two surfaces cannot drift into meaning different things by one colour.
    ///
    /// Lives here rather than beside `CheckInIntensity`, because `Shared/` is UI-free: the
    /// domain owns the scale, the design system owns what it looks like.
    ///
    /// **Colour is never the only channel.** The Log sheet prints the chosen value as a
    /// numeral beside the track and reports it to VoiceOver, and the track's position carries
    /// it a third time. A ten-step ramp is not distinguishable by hue alone to every user,
    /// and a scale only a trichromat can read is not a scale.
    static func intensity(_ value: CheckInIntensity) -> Color {
        rampColour(at: value.normalized)
    }

    /// The whole ramp, for the slider's track. Drawn end to end regardless of the current
    /// value — the track shows what the scale means, not how far along it the user is.
    static let intensityGradient = Gradient(colors: intensityRamp.map(Color.init(hex:)))

    /// The ramp sampled at `position`, 0 to 1, mixing the two stops it falls between.
    ///
    /// Component-wise in sRGB, which is not perceptually uniform — a mix of two stops can sit
    /// a little darker than an eye expects. Acceptable because the stops are close enough
    /// together that no mix travels far, and the alternative is an Oklab conversion for a
    /// difference nothing on screen would show.
    private static func rampColour(at position: Double) -> Color {
        let lastIndex = intensityRamp.count - 1
        let scaled = min(max(position, 0), 1) * Double(lastIndex)
        let lower = min(Int(scaled), lastIndex)
        let upper = min(lower + 1, lastIndex)
        let progress = scaled - Double(lower)

        return Color(
            .sRGB,
            red: mix(intensityRamp[lower], intensityRamp[upper], shift: 16, progress: progress),
            green: mix(intensityRamp[lower], intensityRamp[upper], shift: 8, progress: progress),
            blue: mix(intensityRamp[lower], intensityRamp[upper], shift: 0, progress: progress),
            opacity: 1
        )
    }

    /// One 0–1 colour component, interpolated between two `0xRRGGBB` literals.
    private static func mix(_ from: UInt32, _ to: UInt32,
                            shift: UInt32, progress: Double) -> Double {
        let start = Double((from >> shift) & 0xFF) / 255
        let end = Double((to >> shift) & 0xFF) / 255
        return start + (end - start) * progress
    }
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
