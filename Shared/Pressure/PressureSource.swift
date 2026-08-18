import Foundation

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

    /// Whether the Motion & Fitness prompt has already been put in front of the user.
    ///
    /// `CMAltimeter` has no authorisation call of its own — the prompt is raised by the
    /// first reading. So this is what a caller reads when it must **not** raise one: the
    /// launch sample runs from `App.init`, before onboarding is on screen, and a permission
    /// sheet with no explanation behind it is the one the user declines. Onboarding is what
    /// asks — see `PressureCollectionController.requestAccess()`.
    ///
    /// Says nothing about the *answer*. Granted and denied are both "requested"; a denial
    /// surfaces as `PressureSourceError.notAuthorized` on the next read, which is where it
    /// belongs.
    var isAccessRequested: Bool { get }

    /// Turns the sensor on, takes the first reading it delivers, and turns it off again.
    ///
    /// Already converted to hPa — no kPa crosses this boundary.
    func currentPressure() async throws -> Pressure
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

    /// Nothing here can raise a prompt, so there is never anything for a caller to wait for.
    var isAccessRequested: Bool { true }

    func currentPressure() async throws -> Pressure {
        throw PressureSourceError.barometerUnavailable
    }
}
