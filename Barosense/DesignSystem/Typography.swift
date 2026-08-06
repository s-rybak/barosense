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
}
