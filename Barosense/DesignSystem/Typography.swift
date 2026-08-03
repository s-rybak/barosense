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
}
