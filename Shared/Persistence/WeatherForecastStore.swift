import Foundation

/// The forecast archive.
///
/// **Append-only per issue.** A row is identified by the pair `(issuedAt, validAt)`, never by
/// `validAt` alone, so a newer issue covering the same hour lands beside the old one instead
/// of on top of it. That is the single rule the whole no-look-ahead guarantee rests on
/// (`.claude/context/pressure-forecast-spec.md` §4.5): a table that overwrote by `validAt`
/// would turn every stored forecast into hindsight the moment the next request landed.
///
/// The reads are shaped by the two questions anything asks. Features ask "what was knowable at
/// `t`, about the hours after `t`", which is `points(issuedAtOrBefore:validIn:)`. The chart and
/// the budget ask "what is the newest issue", which is the other two.
protocol WeatherForecastStore: Sendable {

    /// Inserts points, replacing any row with the same `(issuedAt, validAt)` pair. Empty input
    /// is a no-op and must not force a write.
    func save(_ points: [WeatherForecastPoint]) async throws

    /// Every point that was **knowable at `instant`** and describes an hour inside `range`,
    /// ascending by `validAt` then `issuedAt`.
    ///
    /// The `issuedAt <= instant` filter is the leak guard, applied in the store rather than
    /// left to each caller: a filter that every reader has to remember is a filter one reader
    /// will forget, and the failure is silent and looks like a great model.
    func points(issuedAtOrBefore instant: Date,
                validIn range: Range<Date>) async throws -> [WeatherForecastPoint]

    /// The newest issue at or before `instant`, or `nil` when the archive holds nothing.
    func mostRecentIssuedAt(atOrBefore instant: Date) async throws -> Date?

    /// One issue's points, ascending by `validAt`.
    func points(issuedAt: Date) async throws -> [WeatherForecastPoint]

    /// Distinct issue instants inside `range`, ascending.
    ///
    /// What `WeatherRequestBudget` counts. Counting issues rather than rows is the point: one
    /// request writes 240-odd rows and spends one unit of quota, and the number the budget
    /// bounds is requests.
    func issueTimes(in range: Range<Date>) async throws -> [Date]

    /// Retention. Drops rows describing hours older than `date`, and reports how many went.
    @discardableResult
    func deletePoints(validBefore date: Date) async throws -> Int

    /// Removes the whole archive. Part of "delete my data".
    func deleteAllForecasts() async throws
}

/// Non-persistent `WeatherForecastStore` for unit tests and previews.
///
/// Filtering and sorting on read, like the other in-memory doubles: acceptable at the sizes a
/// test holds, and the durable store leaves both to SQLite and an index.
actor InMemoryWeatherForecastStore: WeatherForecastStore {

    /// Keyed on the pair, which is what makes the append-only-per-issue rule true here as well
    /// as in SQLite. A dictionary keyed on `validAt` alone would reproduce exactly the
    /// overwrite this store exists to rule out, and the in-memory double is where most tests
    /// would notice.
    private struct Key: Hashable {
        let issuedAt: Date
        let validAt: Date
    }

    private var storage: [Key: WeatherForecastPoint] = [:]

    init(_ points: [WeatherForecastPoint] = []) {
        for point in points {
            storage[Key(issuedAt: point.issuedAt, validAt: point.validAt)] = point
        }
    }

    func save(_ points: [WeatherForecastPoint]) {
        for point in points {
            storage[Key(issuedAt: point.issuedAt, validAt: point.validAt)] = point
        }
    }

    func points(issuedAtOrBefore instant: Date,
                validIn range: Range<Date>) -> [WeatherForecastPoint] {
        storage.values
            .filter { $0.issuedAt <= instant && range.contains($0.validAt) }
            .sorted { ($0.validAt, $0.issuedAt) < ($1.validAt, $1.issuedAt) }
    }

    func mostRecentIssuedAt(atOrBefore instant: Date) -> Date? {
        storage.values
            .filter { $0.issuedAt <= instant }
            .map(\.issuedAt)
            .max()
    }

    func points(issuedAt: Date) -> [WeatherForecastPoint] {
        storage.values
            .filter { $0.issuedAt == issuedAt }
            .sorted { $0.validAt < $1.validAt }
    }

    func issueTimes(in range: Range<Date>) -> [Date] {
        Set(storage.values.map(\.issuedAt))
            .filter { range.contains($0) }
            .sorted()
    }

    @discardableResult
    func deletePoints(validBefore date: Date) -> Int {
        let expired = storage.filter { $0.value.validAt < date }.map(\.key)
        for key in expired {
            storage[key] = nil
        }
        return expired.count
    }

    func deleteAllForecasts() {
        storage.removeAll()
    }
}
