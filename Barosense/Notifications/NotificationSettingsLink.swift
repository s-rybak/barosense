import UIKit

/// Opens Barosense's own page in iOS Settings, where notification permission lives.
///
/// Needed for the same reason `HealthAppLink` is: the app cannot undo or re-ask its own
/// authorisation once the prompt has been answered, so a switch that could not send the user
/// anywhere would silently do nothing for anyone who tapped "Don't Allow".
enum NotificationSettingsLink {

    @MainActor
    static func open() {
        guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }

        UIApplication.shared.open(settings)
    }
}
