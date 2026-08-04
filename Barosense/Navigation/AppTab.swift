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
    var label: String {
        switch self {
        case .now: "Now"
        case .history: "History"
        case .log: "Log"
        case .insights: "Insights"
        case .settings: "Settings"
        }
    }

    /// Heading shown on the destination itself.
    var screenTitle: String { label }

    /// One line describing what the destination will hold once it is built.
    var screenSummary: String {
        switch self {
        case .now:
            "Current barometric pressure and how it has moved today."
        case .history:
            "Your past check-ins next to the pressure around them."
        case .log:
            "A short check-in: how you feel right now."
        case .insights:
            "Personal patterns that build up as you keep checking in."
        case .settings:
            "Notifications, stored data, and what Barosense may read."
        }
    }

    /// The centre destination is drawn as a raised accent button, not a flat icon.
    var isAccent: Bool { self == .log }
}
