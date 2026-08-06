import Foundation

/// One reading taken from the Health store, in the app's own vocabulary.
///
/// A value type, like `PressureSample` and `CheckIn`: the feature pipeline consumes this
/// and must be runnable from a plain unit test with no `HKHealthStore` anywhere.
/// Everything HealthKit-shaped stops at `HealthDataReader`.
///
/// The row is deliberately raw — one reading, as recorded, in its own interval. Anything
/// aggregated (a night's total, a daily mean) is derived at the instant a feature is
/// computed, never stored pre-chewed: a stored aggregate fixes the window, and the window
/// is exactly what the no-look-ahead rule constrains (`.claude/context/ml-spec.md` §2.3).
struct HealthSample: Identifiable, Hashable, Codable, Sendable {

    /// The identifier HealthKit gave this object, carried through unchanged.
    ///
    /// This is what makes re-reading idempotent. A refresh re-reads an overlapping window
    /// every time, so the same reading arrives repeatedly; storing it under HealthKit's
    /// own id means it collapses onto one row instead of multiplying into training data.
    let id: UUID

    /// Start of the interval the reading covers. Equal to `end` for an instantaneous
    /// reading — a resting heart rate or a blood-oxygen sample.
    let start: Date

    /// End of the interval, and the instant the reading became knowable.
    ///
    /// This is the field the no-look-ahead rule is stated against: only samples with
    /// `end <= t` may enter a feature computed at `t`. Windowing anywhere downstream is
    /// therefore on `end`, never on `start`.
    let end: Date

    let value: HealthMetricValue

    init(id: UUID, start: Date, end: Date, value: HealthMetricValue) {
        self.id = id
        self.start = start
        self.end = end
        self.value = value
    }

    var kind: HealthMetricKind { value.kind }

    /// Length of the interval, in seconds. Zero for an instantaneous reading.
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

extension HealthSample {

    /// Plausibility gate for a reading arriving from the Health store.
    ///
    /// Same job as `Pressure.isPlausible`: reject a unit mix-up or a corrupt row at the
    /// boundary rather than let it become a training row. A percent reported as 97
    /// instead of 0.97, or an interval that ends before it starts, is a bug in the read
    /// path — not something the model should be asked to learn around.
    var isPlausible: Bool {
        guard end >= start else { return false }
        // A single asleep interval longer than a day is a merge artefact, not a night.
        guard duration <= 24 * 3600 else { return false }
        return value.isPlausible
    }
}

/// Which measurement a `HealthSample` carries.
///
/// Exists so callers can ask the store for one family without pattern-matching on the
/// value. The raw values are persisted and must not be renamed.
enum HealthMetricKind: String, CaseIterable, Codable, Sendable {
    case restingHeartRate
    case oxygenSaturation
    case asleep
}

/// The measured value, with its unit fixed by the case rather than by a comment.
///
/// Modelled the way `Pressure` is: the unit lives in the type, so a blood-oxygen fraction
/// can never be handed to something expecting beats per minute, and a percentage cannot
/// silently stand in for a fraction. A bare `Double` plus a `kind` field would compile in
/// both of those cases.
enum HealthMetricValue: Hashable, Codable, Sendable {

    /// Beats per minute.
    case restingHeartRateBPM(Double)

    /// Fraction of 0...1 — HealthKit's own scale for `.oxygenSaturation` read in
    /// `HKUnit.percent()`. 0.97, not 97.
    case oxygenSaturationFraction(Double)

    /// The user was asleep for this sample's interval.
    ///
    /// Carries no number: the duration *is* `end - start`. Storing it a second time
    /// would let the two disagree after a clamp or a merge, and there would be no way to
    /// tell which one was right.
    case asleep

    var kind: HealthMetricKind {
        switch self {
        case .restingHeartRateBPM: .restingHeartRate
        case .oxygenSaturationFraction: .oxygenSaturation
        case .asleep: .asleep
        }
    }

    /// Ranges wide enough to pass anything a person can actually register and narrow
    /// enough to catch a wrong unit. *Provisional* — widen from real traces, not from
    /// taste.
    var isPlausible: Bool {
        switch self {
        case .restingHeartRateBPM(let bpm): (20...250).contains(bpm)
        case .oxygenSaturationFraction(let fraction): (0.5...1.0).contains(fraction)
        case .asleep: true
        }
    }
}
