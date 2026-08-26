import SwiftUI

/// Colour tokens for the watch screens.
///
/// A separate palette from the phone's `Palette`, and not an oversight. The phone design is
/// a single warm **light** theme on `#F7F5F1`; the watch frames are dark, because a watch
/// face is read against an OLED panel that is off where the pixels are black, and inverting
/// the phone's warm paper onto a wrist would cost battery and legibility at once.
///
/// The two palettes share the accent hues — the tokens below that carry a Figma name are the
/// same values `Palette` uses, so a check-in dot means the same colour on both devices. What
/// differs is only the ground they sit on.
///
/// Raw hex appears only in this file, nowhere else in the watch target — the same rule
/// `Palette` states for the phone.
enum WatchPalette {

    /// The screen. Not pure black: a hairline of lift keeps a card's edge visible, and pure
    /// black would make the rounded card corners disappear into the bezel.
    static let surface = Color(hex: 0x0B0B0D)

    /// A card raised off `surface` — the gauge tiles and the trend plot's ground.
    static let cardSurface = Color(hex: 0x1B1C1F)

    /// A control at rest: an unselected chip, the stepper's buttons.
    static let controlFill = Color(hex: 0x2A2C31)

    /// Primary text on `surface`.
    static let ink = Color(hex: 0xF4F2ED)

    /// Supporting text: the unit, the tendency word, a card's caption.
    static let inkMuted = Color(hex: 0x9CA3B5)

    /// Text on a filled light control — the save action's label.
    static let onLight = Color(hex: 0x17181C)

    /// `color/azure/56` (Royal Blue) — the pressure line, and a selected chip.
    /// Same token as the phone's `Palette.chartLine`.
    static let chartLine = Color(hex: 0x3E6BE0)

    /// Lifted for a dark ground: `chartLine` at 15% lightness on `#0B0B0D` fails contrast
    /// for a 1 pt stroke, so the plot uses this and the fill under it uses `chartLine`.
    static let chartLineOnDark = Color(hex: 0x6C93F5)

    /// `color/red/61` (Burnt Sienna) — a falling tendency, and the intensity numeral at the
    /// top of the scale. Same token as the phone's `Palette.markerWarm`.
    static let markerWarm = Color(hex: 0xE8734F)

    /// `color/spring-green/45` (Chateau Green) — a rising tendency. Same token as the
    /// phone's `Palette.positive`.
    static let positive = Color(hex: 0x3FA66B)

    /// Ring track behind a gauge. Dim enough not to read as a value of its own.
    static let gaugeTrack = Color(hex: 0x33363D)

    /// The disc the app mark is drawn on. A shade off `surface` rather than equal to it, so
    /// the mark still reads as an object on the launch screen instead of dissolving into the
    /// background it sits on.
    static let logoField = Color(hex: 0x24241C)

    /// The mark's outer ring. The one olive in the app, and deliberately not a token used
    /// anywhere else: it belongs to the logo, and reusing it for a control would make a
    /// future logo change a UI change.
    static let logoRing = Color(hex: 0x8A8659)
}

extension Color {

    /// Builds a colour from a `0xRRGGBB` literal in the sRGB space.
    ///
    /// A copy of the phone target's initialiser of the same name, because there is nowhere
    /// else to put it: `Shared/` is UI-free by rule and must not `import SwiftUI`, and the
    /// project has no shared-UI target. The two copies are identical arithmetic on a literal
    /// and cannot drift in behaviour; a shared UI module is the real fix and is a follow-up,
    /// not this change.
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

/// The type ramp for the watch.
///
/// Sizes are the watch frames' own, not the phone's scaled down: a 34 pt numeral on a 40 mm
/// screen is a different design problem from a 34 pt numeral on a phone. Declared
/// `relativeTo:` a text style so Dynamic Type still moves them, which on watchOS is not
/// optional — the system text-size setting is prominent and users do change it.
///
/// The face is the system one. The design specifies Manrope and the font files are not in
/// the repo, exactly as `Typography` records for the phone; naming the custom face here too
/// would resolve to the same system fallback while implying the font is present.
enum WatchTypography {

    /// The pressure figure on the main screen — the one thing read at a glance.
    static let reading = Font.system(size: 38, weight: .heavy, design: .rounded)

    /// The chosen intensity on the check-in form.
    static let intensityValue = Font.system(size: 40, weight: .heavy, design: .rounded)

    /// The figure inside a gauge ring.
    static let gaugeValue = Font.system(size: 17, weight: .heavy, design: .rounded)

    /// The unit and tendency line under the reading, and a gauge's caption.
    static let caption = Font.system(.caption2, design: .rounded).weight(.medium)

    /// A chip's label, and the label of the save action.
    static let control = Font.system(.footnote, design: .rounded).weight(.semibold)
}

/// How a pressure tendency is spoken and coloured on the watch.
///
/// One mapping, used by the main screen's caption, the trend screen's header and the
/// detail screen's gauge, so the three cannot end up describing the same reading with
/// different words. Presentation only — `PressureTrend` itself lives in `Shared/`, which
/// holds no copy and no colour.
enum WatchTrendStyle {

    /// The word under the number. `nil` for `.unknown`: the ordinary state on a fresh
    /// install and after a gap, where the caption is simply absent rather than a guess.
    static func caption(for trend: PressureTrend) -> LocalizedStringKey? {
        switch trend {
        case .rising: "rising"
        case .falling: "falling"
        case .steady: "steady"
        case .unknown: nil
        }
    }

    /// An arrow costs no space and is the one piece of context a bare number lacks.
    static func symbol(for trend: PressureTrend) -> String? {
        switch trend {
        case .rising: "arrow.up.right"
        case .falling: "arrow.down.right"
        case .steady: "arrow.right"
        case .unknown: nil
        }
    }

    /// **Never the only channel.** Every surface that colours a tendency also prints its
    /// word or its arrow beside it, because a red-green pair is exactly the distinction a
    /// large minority of users cannot make.
    ///
    /// Falling is warm and rising is green because that is the direction the app is about —
    /// a falling barometer is the change the user opened the app to notice. It says nothing
    /// about how they will feel.
    static func tint(for trend: PressureTrend) -> Color {
        switch trend {
        case .rising: WatchPalette.positive
        case .falling: WatchPalette.markerWarm
        case .steady, .unknown: WatchPalette.inkMuted
        }
    }
}

/// The colour of one point on the 1–10 check-in scale.
///
/// **A copy of the phone's `Palette.intensity(_:)`, stop for stop.** The same value must
/// produce the same colour on both devices: the dot a watch check-in leaves on the phone's
/// pressure chart is drawn by the phone, and a watch that showed a different colour while the
/// user chose it would be describing the same report two ways.
///
/// Copied rather than shared because there is nowhere to share it from — `Shared/` is UI-free
/// by rule and there is no shared-UI target. The phone's copy is the source of truth; changing
/// a stop there means changing it here. Extracting a design-token layer both targets can read
/// is the real fix and is a follow-up.
enum WatchIntensityRamp {

    /// Five evenly spaced stops, green at 1 to red at 10. See `Palette.intensityRamp` for
    /// which of them are real Figma tokens and which two are not.
    private static let stops: [UInt32] = [
        0x3FA66B, // `color/spring-green/45` (Chateau Green)
        0x84B85A, // not a Figma token
        0xE3A93F, // not a Figma token
        0xE8734F, // `color/red/61` (Burnt Sienna)
        0xD65B4A  // `color/red/56` (Red Damask)
    ]

    /// **Colour is never the only channel.** Every surface using this prints the chosen
    /// value as a numeral beside it and reports it to VoiceOver — a ten-step ramp is not
    /// distinguishable by hue alone to every user.
    static func colour(_ value: CheckInIntensity) -> Color {
        let lastIndex = stops.count - 1
        let scaled = min(max(value.normalized, 0), 1) * Double(lastIndex)
        let lower = min(Int(scaled), lastIndex)
        let upper = min(lower + 1, lastIndex)
        let progress = scaled - Double(lower)

        return Color(
            .sRGB,
            red: mix(stops[lower], stops[upper], shift: 16, progress: progress),
            green: mix(stops[lower], stops[upper], shift: 8, progress: progress),
            blue: mix(stops[lower], stops[upper], shift: 0, progress: progress),
            opacity: 1
        )
    }

    private static func mix(_ lower: UInt32, _ upper: UInt32,
                            shift: UInt32, progress: Double) -> Double {
        let start = Double((lower >> shift) & 0xFF) / 255
        let end = Double((upper >> shift) & 0xFF) / 255
        return start + (end - start) * progress
    }
}
