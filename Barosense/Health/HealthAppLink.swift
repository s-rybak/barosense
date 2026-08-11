import UIKit

/// Opens the Health app so the user can change what Barosense may read.
///
/// Needed because the app cannot undo its own HealthKit authorisation and iOS shows the
/// permission sheet exactly once. After that, Health › Sharing › Apps is the only place
/// the answer can be changed, and a switch that silently does nothing would be worse than
/// no switch at all.
enum HealthAppLink {

    /// `x-apple-health://` opens the Health app; `UIApplication.openSettingsURLString`
    /// opens Barosense's own page in Settings.
    ///
    /// The fallback matters: Health is absent on iPad and on a Mac running iOS apps, and
    /// on those the app's Settings page is the nearest thing to somewhere useful.
    ///
    /// `canOpenURL` is not used — for a non-`http` scheme it needs the scheme declared in
    /// `LSApplicationQueriesSchemes`, which is a permanent manifest entry bought to answer
    /// one question. `open(_:completionHandler:)` reports the same fact and needs nothing.
    @MainActor
    static func open() {
        guard let health = URL(string: "x-apple-health://") else { return }

        UIApplication.shared.open(health) { opened in
            guard !opened, let settings = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            UIApplication.shared.open(settings)
        }
    }
}
