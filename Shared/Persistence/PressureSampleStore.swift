import Foundation

/// Storage for barometer readings.
///
/// The write API is a batch on purpose. A durable write costs an fsync, and on watchOS
/// sampling happens in short opportunistic windows; buffering a window's readings and
/// writing them once keeps the write count proportional to wake-ups (a few per hour)
/// rather than to samples (target ≥1/h, bursty). Do not add a single-sample save — it
/// would make the expensive pattern the easy one.
///
/// No validation here. Callers gate on `Pressure.isPlausible` at the sensor boundary; a
/// store that quietly dropped readings would hide a unit mix-up instead of surfacing it.
protocol PressureSampleStore: Sendable {

    /// Inserts samples, replacing any stored sample carrying the same `id`. Empty input
    /// is a no-op and must not force a write.
    func save(_ samples: [PressureSample]) async throws

    /// Samples whose timestamp falls in the half-open `range`, ascending by timestamp.
    func samples(in range: Range<Date>) async throws -> [PressureSample]

    /// Retention. Drops samples older than `date` and reports how many went, so a
    /// retention pass is observable rather than silently eating history.
    @discardableResult
    func deleteSamples(before date: Date) async throws -> Int
}
