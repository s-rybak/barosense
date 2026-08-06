import Foundation

/// The training log for Health-store readings.
///
/// Deliberately a copy rather than a pointer back into HealthKit. The model is fit on the
/// history the app actually observed, and HealthKit is a moving target: the user can
/// revoke read access, and a source app can rewrite or delete rows underneath us. A run
/// that re-queries HealthKit months later would silently score itself on a different
/// dataset than the one it was fit on, with nothing in the diff to show for it.
///
/// The cost of that choice is a second copy of health data at rest, so the same rule
/// applies here as to `CheckInStore`: an implementation keeps it on-device unless the user
/// has given separate, explicit consent (`CLAUDE.md`, constraint 2). Not a caller's
/// decision.
///
/// Batched writes for the same reason as `PressureSampleStore`: a refresh reads a whole
/// window at once, and one fsync per window beats one per reading.
protocol HealthSampleStore: Sendable {

    /// Inserts samples, replacing any stored sample carrying the same `id`. Empty input is
    /// a no-op and must not force a write.
    ///
    /// Replace-on-same-id is what makes a refresh cheap to repeat: refreshes re-read an
    /// overlapping window, so most of what arrives is already stored.
    func save(_ samples: [HealthSample]) async throws

    /// Samples of one kind whose `end` falls in the half-open `range`, ascending by `end`.
    ///
    /// Windowed on `end`, not `start`: a feature computed at `t` may only see readings
    /// that were complete by `t`, and an asleep interval that began before the window but
    /// ended inside it was not knowable until it ended.
    func samples(of kind: HealthMetricKind, in range: Range<Date>) async throws -> [HealthSample]

    /// Retention. Drops samples that ended before `date` and reports how many went, so a
    /// retention pass is observable rather than silently eating history.
    @discardableResult
    func deleteSamples(before date: Date) async throws -> Int
}
