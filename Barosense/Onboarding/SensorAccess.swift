import Foundation

/// The system permissions onboarding asks for, as the flow is allowed to see them.
///
/// Two sheets, one step. Both are raised from the step that explains what is read
/// (`HealthStep`) and from nowhere else in the flow — a permission the user meets before
/// anything has told them what the app measures is a permission they decline.
///
/// A protocol rather than the two services themselves, because `OnboardingModel` has to
/// stay runnable from a plain unit test: the live pair reaches `HKHealthStore` and
/// `CMAltimeter`, neither of which a test may touch.
@MainActor
protocol SensorAccessRequesting {

    /// Presents the Apple Health sheet for `HealthKitReadSet`.
    ///
    /// Returns when the sheet has been answered — **not** whether anything was granted. iOS
    /// never reports a read grant (`.claude/skills/healthkit_permissions/SKILL.md`), so
    /// there is no outcome to hand back and nothing may branch on one.
    func requestHealthAccess() async

    /// Raises the Motion & Fitness prompt for the barometer.
    ///
    /// Returns nothing for a different reason: `CMAltimeter` answers by delivering a reading
    /// or by not delivering one, and a refusal is a gap in the pressure history rather than
    /// a state the flow could repair. What it *did* answer is read back through
    /// `barometerAccess()` instead, which is the honest shape — the prompt does not report,
    /// the sensor's status does.
    func requestBarometerAccess() async

    /// What Barosense can currently read from Health.
    ///
    /// Never a refusal: iOS does not reveal a read grant, so this reports what came back from
    /// a probe read and nothing more (`HealthAccessState`). The step draws a switch off it and
    /// the switch says "connected", never "denied".
    func healthAccess() async -> HealthAccessState

    /// What the barometer will do for this install right now.
    ///
    /// Synchronous, unlike the Health one: `CMAltimeter.authorizationStatus()` is a local
    /// property read with no query behind it, and putting it behind `await` would suggest a
    /// cost that is not there.
    func barometerAccess() -> BarometerAccessState
}

/// `SensorAccessRequesting` against the real device: the Health store, and the phone's
/// barometer through the controller that owns it.
///
/// Handed the live `PressureCollectionController` rather than building one, so the flow
/// asks through the same object the rest of the app samples through. A second controller
/// would carry its own fifteen-minute rate limit and take a duplicate reading on the first
/// activation after onboarding.
@MainActor
struct DeviceSensorAccess: SensorAccessRequesting {

    let health: any HealthAccessReporting
    let pressure: PressureCollectionController

    /// A throw here means the sheet never appeared — no Health store on this device, most
    /// often. Swallowed for the same reason the outcome is: there is nothing the step could
    /// say about it beyond what the empty Health rows say later anyway.
    func requestHealthAccess() async {
        try? await health.requestAccess()
    }

    func requestBarometerAccess() async {
        await pressure.requestAccess()
    }

    func healthAccess() async -> HealthAccessState {
        await health.accessState()
    }

    func barometerAccess() -> BarometerAccessState {
        pressure.barometerAccess
    }
}

/// Asks for nothing. Previews and tests, which must raise no system sheet.
///
/// Reports both permissions as unasked rather than as granted, so a canvas draws the switches
/// in the one state that is actionable — which is the state worth having in a preview — and a
/// test that never calls a request cannot accidentally assert against a grant nothing gave.
@MainActor
struct NoOpSensorAccess: SensorAccessRequesting {

    var health: HealthAccessState = .notRequested
    var barometer: BarometerAccessState = .notRequested

    func requestHealthAccess() async {}

    func requestBarometerAccess() async {}

    func healthAccess() async -> HealthAccessState { health }

    func barometerAccess() -> BarometerAccessState { barometer }
}
