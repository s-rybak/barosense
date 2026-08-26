import SwiftUI

/// Type ramp from the Barosense Figma library.
///
/// The design specifies Manrope. The font files are **not** in the repo yet, so
/// `Font.custom` silently resolves to the system face at the same size and weight. Drop
/// `Manrope-Regular.ttf` / `Manrope-SemiBold.ttf` into the bundle and list them under
/// `UIAppFonts` and every call site below starts rendering Manrope with no other change.
///
/// Sizes are declared `relativeTo:` a text style so Dynamic Type still scales them.
enum Typography {

    /// `Manrope/SemiBold 11` — tab-bar labels.
    static let tabLabel = Font
        .custom("Manrope-SemiBold", size: 11, relativeTo: .caption2)
        .weight(.semibold)

    /// Screen heading on a placeholder destination.
    static let screenTitle = Font
        .custom("Manrope-SemiBold", size: 28, relativeTo: .title)
        .weight(.semibold)

    /// Supporting line under a screen heading.
    static let screenSummary = Font
        .custom("Manrope-Regular", size: 15, relativeTo: .subheadline)

    /// `Manrope/ExtraBold 18` — the figure on a metric card.
    static let metricValue = Font
        .custom("Manrope-ExtraBold", size: 18, relativeTo: .title3)
        .weight(.heavy)

    /// `Manrope/SemiBold 11` — the caption under a metric figure.
    ///
    /// Same face and size as `tabLabel` today, kept separate because they are different
    /// roles: moving the tab bar's type must not silently resize every card.
    static let metricLabel = Font
        .custom("Manrope-SemiBold", size: 11, relativeTo: .caption2)
        .weight(.semibold)

    /// `Manrope/Regular 12` — a note under a card row, shown only when there is nothing
    /// to put in the cards.
    static let cardNote = Font
        .custom("Manrope-Regular", size: 12, relativeTo: .footnote)

    // MARK: - Onboarding (Figma `7:338`)

    /// `Manrope/ExtraBold 26` — the opening step's heading, the largest type in the app.
    static let onboardingTitleLarge = Font
        .custom("Manrope-ExtraBold", size: 26, relativeTo: .title2)
        .weight(.heavy)

    /// `Manrope/ExtraBold 24` — the heading on most onboarding steps.
    static let onboardingTitle = Font
        .custom("Manrope-ExtraBold", size: 24, relativeTo: .title3)
        .weight(.heavy)

    /// `Manrope/ExtraBold 22` — heading of a step that centres its content around an
    /// icon and therefore has less vertical room.
    static let onboardingTitleCompact = Font
        .custom("Manrope-ExtraBold", size: 22, relativeTo: .title3)
        .weight(.heavy)

    /// `Manrope/Medium 15` — supporting copy under the opening heading.
    static let onboardingBody = Font
        .custom("Manrope-Medium", size: 15, relativeTo: .subheadline)
        .weight(.medium)

    /// `Manrope/Medium 14` — supporting copy elsewhere in the flow.
    static let onboardingBodySmall = Font
        .custom("Manrope-Medium", size: 14, relativeTo: .subheadline)
        .weight(.medium)

    /// `Manrope/Medium 15` — what the user types into a field, and its placeholder.
    static let fieldText = Font
        .custom("Manrope-Medium", size: 15, relativeTo: .subheadline)
        .weight(.medium)

    /// `Manrope/Medium 13` — the unit printed after a field's value.
    static let fieldUnit = Font
        .custom("Manrope-Medium", size: 13, relativeTo: .footnote)
        .weight(.medium)

    /// `Manrope/SemiBold 14` — the label of a chip or a full-width choice row.
    static let choiceLabel = Font
        .custom("Manrope-SemiBold", size: 14, relativeTo: .subheadline)
        .weight(.semibold)

    /// `Manrope/SemiBold 13` — the label of a choice in a three-across row, and of an
    /// informational row.
    static let choiceLabelCompact = Font
        .custom("Manrope-SemiBold", size: 13, relativeTo: .footnote)
        .weight(.semibold)

    /// `Manrope/Medium 13` — the consent sentence beside its checkbox.
    static let consentText = Font
        .custom("Manrope-Medium", size: 13, relativeTo: .footnote)
        .weight(.medium)

    /// `Manrope/Bold 16` — the primary action at the foot of every step.
    static let primaryAction = Font
        .custom("Manrope-Bold", size: 16, relativeTo: .body)
        .weight(.bold)

    /// `Manrope/SemiBold 13` — a tertiary action such as skipping a step.
    static let tertiaryAction = Font
        .custom("Manrope-SemiBold", size: 13, relativeTo: .footnote)
        .weight(.semibold)

    // MARK: - Pressure chart (Figma `7:671`)

    /// `Manrope/Bold 15` — the heading of a card that owns a whole section.
    static let cardTitle = Font
        .custom("Manrope-Bold", size: 15, relativeTo: .subheadline)
        .weight(.bold)

    /// `Manrope/ExtraBold 17` — the pressure figure the chart card prints.
    static let pressureValue = Font
        .custom("Manrope-ExtraBold", size: 17, relativeTo: .title3)
        .weight(.heavy)

    /// `Manrope/SemiBold 11` — the trend caption beside that figure.
    ///
    /// Same face and size as `metricLabel` and `tabLabel`, kept separate for the same
    /// reason they are separate from each other: three different roles that must be able to
    /// move independently.
    static let captionEmphasis = Font
        .custom("Manrope-SemiBold", size: 11, relativeTo: .caption2)
        .weight(.semibold)

    /// `Manrope/Bold 9` — the "now" divider label inside the plot. The smallest type in the
    /// app; it annotates the chart rather than carrying information on its own.
    static let chartAnnotation = Font
        .custom("Manrope-Bold", size: 9, relativeTo: .caption2)
        .weight(.bold)

    /// `Manrope/SemiBold 12` — an unselected option in the range selector.
    static let segmentLabel = Font
        .custom("Manrope-SemiBold", size: 12, relativeTo: .caption)
        .weight(.semibold)

    /// `Manrope/Bold 12` — the selected option. Heavier, not just darker: the design leans
    /// on weight as well as colour, so the selection survives at an accessibility size.
    static let segmentLabelSelected = Font
        .custom("Manrope-Bold", size: 12, relativeTo: .caption)
        .weight(.bold)

    // MARK: - Now meters

    /// `Manrope/Medium 12` — what a meter card's bar measures, printed beside its figure.
    ///
    /// Same face and size as `settingsCaption`, kept separate for the reason the three 11 pt
    /// captions above are separate from each other: it names a measurement rather than
    /// supporting a row, and retuning the settings list must not resize the Now screen.
    ///
    /// No Figma node cited: the two meter cards were handed over as images rather than from
    /// the library, so the size is read off the frame and not from a named text style.
    static let meterLabel = Font
        .custom("Manrope-Medium", size: 12, relativeTo: .caption)
        .weight(.medium)

    // MARK: - Risk card (Figma `7:654`)

    /// `Manrope/Bold 13` — the caption row over the risk headline: when the model expects a
    /// change, and the percentage beside it.
    ///
    /// Same face and size as `navigationAction`, kept separate for the reason the three 11 pt
    /// captions are separate from each other: retuning a navigation bar must not resize the
    /// first line of the Now screen.
    static let riskCaption = Font
        .custom("Manrope-Bold", size: 13, relativeTo: .footnote)
        .weight(.bold)

    /// `Manrope/ExtraBold 22` — the risk card's headline, rendered with `.tracking(-0.44)`
    /// at the call site to match `letter spacing/-0_44`.
    ///
    /// Same face and size as `onboardingTitleCompact`, and separate for the same reason: the
    /// onboarding heading answers to a step frame, this one to a card that also carries a
    /// caption, a chip row and a note.
    static let riskHeadline = Font
        .custom("Manrope-ExtraBold", size: 22, relativeTo: .title3)
        .weight(.heavy)

    // MARK: - Check-in sheet (Figma `7:330`)

    /// `Manrope/Medium 13` — the quiet noun that names a block of the form.
    ///
    /// Same face and size as `fieldUnit`, kept separate for the reason the three 11 pt
    /// captions above are separate: it labels a section rather than annotating a value, and
    /// the two have to be able to move apart.
    static let sectionLabel = Font
        .custom("Manrope-Medium", size: 13, relativeTo: .footnote)
        .weight(.medium)

    /// `Manrope/ExtraBold 34` — the chosen intensity, the largest numeral in the app.
    ///
    /// It is the value the whole sheet exists to capture, and the only part of the slider a
    /// user reads rather than aims at, so it scales with the type ramp while the track and
    /// thumb below it keep their fixed geometry.
    static let intensityValue = Font
        .custom("Manrope-ExtraBold", size: 34, relativeTo: .largeTitle)
        .weight(.heavy)

    // MARK: - Settings (Figma `7:1246`, `7:1308`)

    /// `Manrope/ExtraBold 24` — the heading of a top-level screen.
    ///
    /// Same face and size as `onboardingTitle`, kept separate because the two answer to
    /// different frames: retuning the onboarding heading must not silently resize the
    /// heading of every tab.
    static let screenHeading = Font
        .custom("Manrope-ExtraBold", size: 24, relativeTo: .title3)
        .weight(.heavy)

    /// `Manrope/Bold 15` — the title in a pushed screen's navigation bar.
    static let navigationTitle = Font
        .custom("Manrope-Bold", size: 15, relativeTo: .subheadline)
        .weight(.bold)

    /// `Manrope/Bold 13` — the confirming action in that bar (Save).
    static let navigationAction = Font
        .custom("Manrope-Bold", size: 13, relativeTo: .footnote)
        .weight(.bold)

    /// `Manrope/SemiBold 13` — a tappable label rendered as text rather than a button,
    /// such as "Change photo".
    static let linkAction = Font
        .custom("Manrope-SemiBold", size: 13, relativeTo: .footnote)
        .weight(.semibold)

    /// `Manrope/Medium 14` — the label of a settings row.
    static let settingsRowLabel = Font
        .custom("Manrope-Medium", size: 14, relativeTo: .subheadline)
        .weight(.medium)

    /// `Manrope/Medium 13` — the current value printed at the trailing edge of a row.
    static let settingsRowValue = Font
        .custom("Manrope-Medium", size: 13, relativeTo: .footnote)
        .weight(.medium)

    /// `Manrope/Medium 12` — the supporting line under a card's title, and the caption
    /// under a row that needs one.
    static let settingsCaption = Font
        .custom("Manrope-Medium", size: 12, relativeTo: .caption)
        .weight(.medium)

    /// `Manrope/Bold 12` — an all-caps group heading above a block of fields. Rendered
    /// with `.tracking(0.48)` at the call site, matching `letter spacing/0_48`.
    static let sectionHeader = Font
        .custom("Manrope-Bold", size: 12, relativeTo: .caption)
        .weight(.bold)

    /// `Manrope/SemiBold 14` — an action that removes something, drawn as bare text.
    static let destructiveAction = Font
        .custom("Manrope-SemiBold", size: 14, relativeTo: .subheadline)
        .weight(.semibold)

    /// `Manrope/Bold 24` — the initial standing in for a photo on the large avatar.
    static let avatarInitial = Font
        .custom("Manrope-Bold", size: 24, relativeTo: .title3)
        .weight(.bold)

    /// `Manrope/Bold 18` — the same initial on the 48 pt avatar in the settings list.
    static let avatarInitialCompact = Font
        .custom("Manrope-Bold", size: 18, relativeTo: .title3)
        .weight(.bold)
}
