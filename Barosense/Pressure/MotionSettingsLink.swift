import UIKit

/// Opens Barosense's own page in iOS Settings, where Motion & Fitness lives.
///
/// A third type beside `LocationSettingsLink` and `NotificationSettingsLink` rather than a
/// shared one, and the same destination as both. The repetition is deliberate: what differs
/// between them is not the URL but *which* permission a call site is talking about, and a
/// single `SettingsLink.open()` would leave that unsaid at every use. Collapsing them is worth
/// doing the day one of them needs a different destination, which none of them does today.
///
/// Needed at all because `CMAltimeter` raises its prompt exactly once per install — the first
/// time the sensor is started — and after a refusal every later start simply fails. A switch
/// that kept restarting the sensor would be a control that visibly does nothing.
enum MotionSettingsLink {

    @MainActor
    static func open() {
        guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }

        UIApplication.shared.open(settings)
    }
}
