import Foundation

/// What the barometer will actually do for this install, as a screen is allowed to see it.
///
/// `CMAltimeter` has no authorisation *call* — the first reading is what raises the Motion &
/// Fitness prompt — but it does have `authorizationStatus()`, and unlike HealthKit's read
/// grants that status is truthful in both directions. So the barometer is the one permission
/// in this app a switch can honestly reflect: on means readings are being taken, off means
/// they are not, and each "off" has a different repair.
///
/// Modelled after `HealthAccessState` and deliberately not merged with it. The two answer the
/// same question about different subsystems, and the Health one cannot report a refusal at all
/// — folding them together would invite a caption that says "denied" about a state HealthKit
/// never reveals.
enum BarometerAccessState: Equatable, Sendable {

    /// No barometer on this device — every simulator, and iPad. Nothing to grant, so a
    /// control for it is inert rather than merely off.
    case unavailable

    /// The prompt has never been put in front of the user. Asking shows it, so the control is
    /// actionable.
    case notRequested

    /// Motion & Fitness is granted and readings are being taken.
    case granted

    /// The user said no, or a device policy says no. Only iOS Settings can undo it — the
    /// prompt is granted once per install and asking again does nothing.
    case denied

    /// Whether the app itself can still put the system prompt on screen.
    var canPresentPrompt: Bool { self == .notRequested }

    /// Whether a switch drawn for this should read as on.
    var isCollecting: Bool { self == .granted }

    /// Whether a switch drawn for this responds to a tap at all. False where there is nothing
    /// on this device to grant.
    var isInteractive: Bool { self != .unavailable }
}

/// The barometer, as the rest of the app is allowed to see it.
///
/// Declared next to its consumer (`PressureSampleRecorder`) for the same reason
/// `HealthDataReader` is: the recorder, the chart and every test depend on this and not on
/// `CMAltimeter`, so the pipeline runs from a plain XCTest with synthetic input.
///
/// **One reading per call, not a stream.** A subscription is the shape that invites a
/// long-lived sampling loop, and `CMAltimeter` left running reports at roughly 1 Hz for as
/// long as the app is on screen — thousands of readings an hour to store four of. Making
/// the cheap pattern the only pattern means a caller has to write a timer on purpose rather
/// than by accident.
protocol PressureSource: Sendable {

    /// Whether this device has a barometer at all.
    ///
    /// `false` on every simulator and on hardware without the sensor. Not an error state:
    /// the app keeps working, the log simply does not grow from this device.
    var isAvailable: Bool { get }

    /// What the sensor will do for this install right now.
    ///
    /// Read by two different callers wanting two different things from it. The launch sample
    /// runs from `App.init`, before onboarding is on screen, and must **not** raise a prompt —
    /// a permission sheet with no explanation behind it is the one the user declines — so it
    /// reads this to find out whether the question has been settled. Onboarding's Health step
    /// reads the same value to draw a switch that says whether readings are actually being
    /// taken. See `PressureCollectionController.requestAccess()`.
    var access: BarometerAccessState { get }

    /// Turns the sensor on, takes the first reading it delivers, and turns it off again.
    ///
    /// Already converted to hPa — no kPa crosses this boundary.
    func currentPressure() async throws -> Pressure
}

extension PressureSource {

    /// Whether the prompt has already been put in front of the user, either way it was
    /// answered.
    ///
    /// Kept as a derived boolean rather than pushed onto every call site, because the launch
    /// gate genuinely does not care *which* answer was given: granted and denied both mean
    /// sampling can proceed without a sheet appearing over a screen that has explained
    /// nothing.
    var isAccessRequested: Bool { access != .notRequested }
}

/// Errors this app raises itself at the barometer boundary. Errors originating inside
/// CoreMotion are propagated unchanged.
enum PressureSourceError: Error, Sendable, Equatable {

    /// No barometer on this device, or the sensor is switched off system-wide.
    case barometerUnavailable

    /// Motion & Fitness access is denied or restricted. Distinguishable from
    /// `barometerUnavailable` because this one the user can undo in Settings.
    case notAuthorized

    /// The sensor was started but delivered nothing inside the timeout. This is a gap in
    /// the history, not a failure worth surfacing.
    case timedOut

    /// The reading arrived but failed `Pressure.isPlausible`.
    ///
    /// Carries the value so a unit mix-up is visible in a test failure rather than
    /// silently swallowed. Never logged — see the note on `PressureSampleRecorder`.
    case implausibleReading(hectopascals: Double)
}

/// Used where there is no barometer to talk to: SwiftUI previews, and the watch target,
/// which displays what the phone measured rather than measuring anything itself (see
/// `PressureDisplayLink`).
struct UnavailablePressureSource: PressureSource {

    var isAvailable: Bool { false }

    /// Nothing here can raise a prompt, and there is nothing to grant. `isAccessRequested`
    /// derives to `true`, so the launch gate still lets a caller through rather than waiting
    /// for an answer that will never come.
    var access: BarometerAccessState { .unavailable }

    func currentPressure() async throws -> Pressure {
        throw PressureSourceError.barometerUnavailable
    }
}
