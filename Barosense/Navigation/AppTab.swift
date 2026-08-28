import SwiftUI

/// The five destinations of the root tab bar, in display order (Figma `7:708`).
enum AppTab: String, CaseIterable, Identifiable {
    case now
    case history
    case log
    case insights
    case settings

    var id: String { rawValue }

    /// Tab-bar label. One short word each, so the bar stays readable at a glance.
    ///
    /// `LocalizedStringKey`, not `String`: `Text(someString)` is verbatim and would leave
    /// the whole bar in the base language whatever the user picked in Settings.
    var label: LocalizedStringKey {
        switch self {
        case .now: "Now"
        case .history: "History"
        case .log: "Log"
        case .insights: "Insights"
        case .settings: "Settings"
        }
    }

    /// The centre destination is drawn as a raised accent button, not a flat icon.
    var isAccent: Bool { self == .log }
}
