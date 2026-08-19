import Foundation
import SwiftData

/// On-disk row behind `SwiftDataWeatherForecastStore`.
///
/// Uniqueness is on `key`, a rendering of the `(issuedAt, validAt)` pair, because SwiftData has
/// no compound unique constraint. It is not a nicety: uniqueness on `validAt` alone is exactly
/// the overwrite that turns a stored forecast into hindsight, and a `@Attribute(.unique)` is
/// the one place that can be enforced rather than remembered.
@Model
final class PersistedWeatherForecastPoint {

    /// Indexed on both dates. Every read filters on one of them — features on `issuedAt` and
    /// `validAt` together, the budget on `issuedAt`, retention on `validAt` — and this table
    /// gains ~240 rows per request.
    #Index<PersistedWeatherForecastPoint>([\.issuedAt], [\.validAt])

    @Attribute(.unique) var key: String
    var issuedAt: Date
    var validAt: Date
    var meanSeaLevelPressureHPa: Double
    var temperatureC: Double

    init(from point: WeatherForecastPoint) {
        self.key = Self.key(issuedAt: point.issuedAt, validAt: point.validAt)
        self.issuedAt = point.issuedAt
        self.validAt = point.validAt
        self.meanSeaLevelPressureHPa = point.meanSeaLevelPressureHPa
        self.temperatureC = point.temperatureC
    }

    /// Whole seconds since the epoch, both dates. Whole seconds because the two sides of a
    /// round trip must render identically, and a `Double` with sub-millisecond noise in it
    /// would produce two keys for one row.
    static func key(issuedAt: Date, validAt: Date) -> String {
        "\(Int(issuedAt.timeIntervalSince1970))/\(Int(validAt.timeIntervalSince1970))"
    }

    func apply(_ point: WeatherForecastPoint) {
        meanSeaLevelPressureHPa = point.meanSeaLevelPressureHPa
        temperatureC = point.temperatureC
    }

    func asPoint() -> WeatherForecastPoint {
        WeatherForecastPoint(issuedAt: issuedAt,
                             validAt: validAt,
                             meanSeaLevelPressureHPa: meanSeaLevelPressureHPa,
                             temperatureC: temperatureC)
    }
}

/// Durable `WeatherForecastStore`.
///
/// Its own container, like the sensor logs and for the same reason: this is machine-produced
/// weather data, not the profile / check-in / tag graph, and `BarosenseModelContainer`'s schema
/// is a deliberate list of what belongs in it.
///
/// **Size.** Four requests a day × ~240 hourly points × 90 days ≈ 86 000 rows at the horizon,
/// each five small columns. That is well under the barometer log's 175 000, and the retention
/// pass keeps it from growing past it.
@ModelActor
actor SwiftDataWeatherForecastStore: WeatherForecastStore {

    private static let storeFileName = "WeatherForecasts.store"

    static func makePersistent() throws -> SwiftDataWeatherForecastStore {
        SwiftDataWeatherForecastStore(modelContainer: try makeContainer(inMemory: false))
    }

    static func makeInMemory() throws -> SwiftDataWeatherForecastStore {
        SwiftDataWeatherForecastStore(modelContainer: try makeContainer(inMemory: true))
    }

    /// The URL is explicit rather than derived from a configuration name, for the reason
    /// `BarosenseModelContainer.storeURL(fileName:)` spells out: the name-based initialiser
    /// follows the app-group entitlement into a directory nothing has created, and the open
    /// then fails on a clean install.
    private static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema([PersistedWeatherForecastPoint.self])
        do {
            let configuration = if inMemory {
                ModelConfiguration("WeatherForecasts.InMemory",
                                   schema: schema,
                                   isStoredInMemoryOnly: true,
                                   cloudKitDatabase: .none)
            } else {
                ModelConfiguration(schema: schema,
                                   url: try BarosenseModelContainer.storeURL(fileName: storeFileName),
                                   cloudKitDatabase: .none)
            }
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            throw PersistenceError.containerUnavailable(underlying: error)
        }
    }

    func save(_ points: [WeatherForecastPoint]) throws {
        guard !points.isEmpty else { return }

        var byKey: [String: WeatherForecastPoint] = [:]
        for point in points {
            byKey[PersistedWeatherForecastPoint.key(issuedAt: point.issuedAt,
                                                    validAt: point.validAt)] = point
        }

        let keys = Array(byKey.keys)
        let descriptor = FetchDescriptor<PersistedWeatherForecastPoint>(
            predicate: #Predicate { keys.contains($0.key) }
        )
        let existing = Dictionary(uniqueKeysWithValues:
            try modelContext.fetch(descriptor).map { ($0.key, $0) })

        for (key, point) in byKey {
            if let row = existing[key] {
                // Same issue, same hour, different numbers: a retry of one request. Updating
                // is right and is not an overwrite of history — the pair that identifies the
                // row has not changed.
                row.apply(point)
            } else {
                modelContext.insert(PersistedWeatherForecastPoint(from: point))
            }
        }

        try modelContext.save()
    }

    func points(issuedAtOrBefore instant: Date,
                validIn range: Range<Date>) throws -> [WeatherForecastPoint] {
        let lower = range.lowerBound
        let upper = range.upperBound

        let descriptor = FetchDescriptor<PersistedWeatherForecastPoint>(
            predicate: #Predicate {
                $0.issuedAt <= instant && $0.validAt >= lower && $0.validAt < upper
            },
            sortBy: [SortDescriptor(\.validAt, order: .forward),
                     SortDescriptor(\.issuedAt, order: .forward)]
        )

        return try modelContext.fetch(descriptor).map { $0.asPoint() }
    }

    func mostRecentIssuedAt(atOrBefore instant: Date) throws -> Date? {
        var descriptor = FetchDescriptor<PersistedWeatherForecastPoint>(
            predicate: #Predicate { $0.issuedAt <= instant },
            sortBy: [SortDescriptor(\.issuedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first?.issuedAt
    }

    func points(issuedAt: Date) throws -> [WeatherForecastPoint] {
        let descriptor = FetchDescriptor<PersistedWeatherForecastPoint>(
            predicate: #Predicate { $0.issuedAt == issuedAt },
            sortBy: [SortDescriptor(\.validAt, order: .forward)]
        )

        return try modelContext.fetch(descriptor).map { $0.asPoint() }
    }

    func issueTimes(in range: Range<Date>) throws -> [Date] {
        let lower = range.lowerBound
        let upper = range.upperBound

        let descriptor = FetchDescriptor<PersistedWeatherForecastPoint>(
            predicate: #Predicate { $0.issuedAt >= lower && $0.issuedAt < upper },
            sortBy: [SortDescriptor(\.issuedAt, order: .forward)]
        )

        // Distinct in Swift rather than in the query: SwiftData has no `DISTINCT`, and the
        // window this is ever asked for is one local day — at most four issues, so a handful
        // of hundred rows.
        var seen: Set<Date> = []
        return try modelContext.fetch(descriptor)
            .map(\.issuedAt)
            .filter { seen.insert($0).inserted }
    }

    @discardableResult
    func deletePoints(validBefore date: Date) throws -> Int {
        let descriptor = FetchDescriptor<PersistedWeatherForecastPoint>(
            predicate: #Predicate { $0.validAt < date }
        )
        let expired = try modelContext.fetch(descriptor)
        let count = expired.count
        for row in expired {
            modelContext.delete(row)
        }
        if count > 0 {
            try modelContext.save()
        }
        return count
    }

    func deleteAllForecasts() throws {
        let rows = try modelContext.fetch(FetchDescriptor<PersistedWeatherForecastPoint>())
        guard !rows.isEmpty else { return }

        for row in rows {
            modelContext.delete(row)
        }
        try modelContext.save()
    }
}
