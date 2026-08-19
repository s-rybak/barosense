import UIKit

/// Opens Barosense's own page in iOS Settings, where the location permission lives.
///
/// Needed for the reason `HealthAppLink` and `NotificationSettingsLink` are needed:
/// `requestWhenInUseAuthorization()` puts a dialog on screen exactly once per install, and
/// after it has been answered the call silently does nothing. A row that kept calling it
/// would be a control that visibly does nothing, which is worse than no control.
///
/// Also the destination for a *granted* row, not only a refused one. Someone who wants to
/// downgrade from full to reduced accuracy, or to withdraw the grant, can only do it there.
enum LocationSettingsLink {

    @MainActor
    static func open() {
        guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }

        UIApplication.shared.open(settings)
    }
}
