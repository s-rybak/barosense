import Foundation

/// The Health store, as the rest of the app is allowed to see it.
///
/// Declared next to its consumer (`HealthSampleRecorder`) so the recorder, the snapshot
/// builder and every test depend on this and not on `HKHealthStore`. That is the whole
/// point: the pipeline has to run from a plain XCTest with synthetic input, and a
/// protocol is the only thing that actually enforces it.
protocol HealthDataReader: Sendable {

    /// Asks the user for read access to the concrete reader's configured HealthKit types.
    ///
    /// Returning normally means the sheet was handled, **not** that anything was granted:
    /// iOS deliberately does not reveal read-authorisation state, so a denial is
    /// indistinguishable from an empty Health store. Nothing may branch on the outcome —
    /// see `.claude/skills/healthkit_permissions/SKILL.md`.
    func requestAuthorization() async throws

    /// Readings of one kind whose `end` falls in the half-open `range`, ascending by
    /// `end`. An empty result is the normal state, not an error.
    func samples(of kind: HealthMetricKind, in range: Range<Date>) async throws -> [HealthSample]
}

/// Errors this app raises itself. Errors originating inside HealthKit are propagated
/// unchanged — re-wrapping them would only hide their codes.
enum HealthDataError: Error, Sendable {

    /// The device has no Health store at all. Every metric stays empty; nothing else in
    /// the app is affected.
    case healthDataUnavailable
}
