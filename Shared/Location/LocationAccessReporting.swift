import Foundation

/// How precisely the user agreed to be located.
///
/// **Both cases are working states.** The epochs round every coordinate to 0.1° (~11 km) and
/// WeatherKit's own grid is coarser than a GPS fix, so `.reduced` covers this feature
/// completely. Drawing it as a fault would push the user toward granting precision the app
/// has no consumer for, which is the surgical-permissions rule (`CLAUDE.md` constraint 3)
/// applied to Location instead of HealthKit.
enum LocationAccuracy: String, Hashable, Sendable {

    /// `NSLocationDefaultAccuracyReduced`, or the user's own choice in Settings. The shipped
    /// default, and the state the app is designed against.
    case reduced

    /// Full precision. Accepted, immediately rounded away, never asked for.
    case full
}

/// What Barosense may do with the user's location right now.
///
/// The mirror of `HealthAccessState`, and deliberately simpler. HealthKit will not report a
/// read grant at all, which is why that type carries proven-grants-but-never-inferred-refusals
/// asymmetry; CoreLocation reports its authorisation honestly, so this enum is just that
/// answer with the two "nothing to do here" cases separated out.
///
/// Four states rather than a `Bool` because tapping the row has to do four different things —
/// see `.claude/context/pressure-forecast-spec.md` §4.10. A switch that silently did nothing
/// after a refusal is the failure `HealthAppLink` and `NotificationSettingsLink` already
/// exist to avoid.
enum LocationAccessState: Equatable, Sendable {

    /// Location services are off for the whole device. Nothing the app can ask for, so the
    /// row is inert and explains why rather than offering a control.
    case unavailable

    /// `.notDetermined`. The one state in which a system prompt can still be raised, so the
    /// row leads to the explanatory screen that precedes it.
    case notRequested

    /// `.denied` or `.restricted`. iOS will not present the prompt a second time, so the row
    /// leads to Settings.app — the only place this can now be changed.
    case denied

    /// `.authorizedWhenInUse` or `.authorizedAlways`.
    ///
    /// The app never asks for `.authorizedAlways` and never uses it: location is read in the
    /// foreground only (§4.3), because a when-in-use app cannot start location updates from a
    /// background task and `CLBackgroundActivitySession` costs a permanent status indicator
    /// for a forecast refreshed four times a day.
    case granted(accuracy: LocationAccuracy)

    /// Whether a coordinate can be obtained at all. `true` for both accuracies.
    var isGranted: Bool {
        if case .granted = self { return true }
        return false
    }

    /// Whether asking would still put a system prompt on screen. `false` everywhere else,
    /// which is what stops the app raising a dialog iOS will silently swallow.
    var canPresentPrompt: Bool { self == .notRequested }

    /// Whether the only remaining route is Settings.app.
    var needsSystemSettings: Bool {
        switch self {
        case .denied: true
        case .granted: true
        case .unavailable, .notRequested: false
        }
    }

    /// Whether the row is tappable. Everything except a device with location services off.
    var isInteractive: Bool { self != .unavailable }
}

/// The location permission as the Settings row and the forecast scheduler are allowed to see
/// it.
///
/// Declared in `Shared/` and free of `import UIKit`, like `HealthAccessReporting`: the state
/// drives a `WeatherRequestBudget` decision as well as a row, and the budget has to be
/// runnable from a unit test.
protocol LocationAccessReporting: Sendable {

    /// Current authorisation.
    ///
    /// `async` because deciding `.unavailable` means asking whether location services are
    /// enabled device-wide, and Apple documents `locationServicesEnabled()` as able to block
    /// when it is called before the daemon has answered. Making the whole protocol
    /// asynchronous is what keeps that off the main actor without a per-implementation
    /// workaround.
    func accessState() async -> LocationAccessState

    /// Raises the system prompt, and returns once it has been answered.
    ///
    /// Does nothing at all in every state but `.notRequested` — iOS answers a repeat request
    /// from its own record without showing anything. Callers re-read `accessState()`
    /// afterwards rather than branching on this returning; that is the only way to find out
    /// what was actually granted.
    func requestAccess() async
}

/// A reporter for a device with location services switched off, and for previews.
///
/// Reports `.unavailable`, so a canvas refresh cannot put a system prompt on screen.
struct UnavailableLocationAccessReporter: LocationAccessReporting {
    func accessState() async -> LocationAccessState { .unavailable }
    func requestAccess() async {}
}

/// A reporter that has never been asked and never asks.
///
/// The preview double, and the reason acceptance criterion 10 exists: a `#Preview` of
/// Settings renders the actionable state of the location row — the interesting one — without
/// any path from that canvas to `CLLocationManager`. Same contract as
/// `NoOpNotificationDeliverer`: it reports the state that makes the control live and refuses
/// to do the thing the control would do.
struct NoOpLocationAccessReporter: LocationAccessReporting {
    func accessState() async -> LocationAccessState { .notRequested }
    func requestAccess() async {}
}
