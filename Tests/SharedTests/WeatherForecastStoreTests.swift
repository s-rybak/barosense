import XCTest
@testable import Barosense

/// The forecast archive, on both implementations. The append-only-per-issue rule is the one
/// that matters: everything the no-look-ahead guarantee rests on is a consequence of it.
final class WeatherForecastStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Append-only per issue

    /// The whole design in one case. A newer issue covering the same hour is a **second row**,
    /// not a replacement — overwrite by `validAt` and every stored forecast silently becomes
    /// hindsight, which validates beautifully and fails in production.
    func testANewerIssueForTheSameHourIsASecondRow() async throws {
        for store in try makeStores() {
            let hour = now.addingTimeInterval(6 * 3600)
            try await store.save([point(issuedAt: now, validAt: hour, pressure: 1013)])
            try await store.save([point(issuedAt: now.addingTimeInterval(3600),
                                        validAt: hour,
                                        pressure: 1009)])

            let rows = try await store.points(issuedAtOrBefore: .distantFuture,
                                              validIn: everything)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(Set(rows.map(\.meanSeaLevelPressureHPa)), [1013, 1009])
        }
    }

    /// A retry of the *same* request is not a second row. The pair identifies the row, and
    /// re-saving it corrects numbers rather than rewriting history.
    func testResavingTheSameIssueAndHourUpdatesInPlace() async throws {
        for store in try makeStores() {
            let hour = now.addingTimeInterval(3600)
            try await store.save([point(issuedAt: now, validAt: hour, pressure: 1013)])
            try await store.save([point(issuedAt: now, validAt: hour, pressure: 1014)])

            let rows = try await store.points(issuedAtOrBefore: .distantFuture,
                                              validIn: everything)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.meanSeaLevelPressureHPa, 1014)
        }
    }

    // MARK: - The leak guard

    /// The filter that stops a feature reading a forecast the device did not have yet. Applied
    /// in the store rather than left to each caller — a filter every reader has to remember is
    /// one a reader will forget, and the failure is silent.
    func testAReadNeverSeesAnIssueMadeAfterTheInstantAsked() async throws {
        for store in try makeStores() {
            let hour = now.addingTimeInterval(12 * 3600)
            try await store.save([
                point(issuedAt: now, validAt: hour, pressure: 1013),
                point(issuedAt: now.addingTimeInterval(6 * 3600), validAt: hour, pressure: 1005)
            ])

            let knowable = try await store.points(issuedAtOrBefore: now.addingTimeInterval(60),
                                                  validIn: everything)

            XCTAssertEqual(knowable.count, 1)
            XCTAssertEqual(knowable.first?.meanSeaLevelPressureHPa, 1013)
        }
    }

    func testTheNewestIssueIsAlsoBoundedByTheInstantAsked() async throws {
        for store in try makeStores() {
            try await store.save([
                point(issuedAt: now, validAt: now, pressure: 1013),
                point(issuedAt: now.addingTimeInterval(4 * 3600), validAt: now, pressure: 1010)
            ])

            let newest = try await store.mostRecentIssuedAt(atOrBefore: now.addingTimeInterval(60))

            XCTAssertEqual(newest, now)
        }
    }

    // MARK: - Issue counting

    /// What the budget counts. One request writes hundreds of rows and spends one unit of
    /// quota, so the number bounded is issues rather than rows.
    func testIssueTimesAreDistinctAndWindowed() async throws {
        for store in try makeStores() {
            try await store.save([
                point(issuedAt: now, validAt: now.addingTimeInterval(3600), pressure: 1013),
                point(issuedAt: now, validAt: now.addingTimeInterval(7200), pressure: 1012),
                point(issuedAt: now.addingTimeInterval(4 * 3600),
                      validAt: now.addingTimeInterval(5 * 3600),
                      pressure: 1011),
                point(issuedAt: now.addingTimeInterval(-48 * 3600),
                      validAt: now.addingTimeInterval(-47 * 3600),
                      pressure: 1020)
            ])

            let window = now.addingTimeInterval(-3600)..<now.addingTimeInterval(24 * 3600)
            let issues = try await store.issueTimes(in: window)

            XCTAssertEqual(issues, [now, now.addingTimeInterval(4 * 3600)])
        }
    }

    // MARK: - Retention

    func testRetentionDropsRowsByTheHourTheyDescribe() async throws {
        for store in try makeStores() {
            try await store.save([
                point(issuedAt: now.addingTimeInterval(-100 * 86_400),
                      validAt: now.addingTimeInterval(-100 * 86_400),
                      pressure: 1000),
                point(issuedAt: now, validAt: now, pressure: 1013)
            ])

            let dropped = try await store.deletePoints(
                validBefore: now.addingTimeInterval(-90 * 86_400)
            )
            let remaining = try await store.points(issuedAtOrBefore: .distantFuture,
                                                   validIn: everything)

            XCTAssertEqual(dropped, 1)
            XCTAssertEqual(remaining.count, 1)
        }
    }

    func testDeletingEverythingEmptiesTheArchive() async throws {
        for store in try makeStores() {
            try await store.save([point(issuedAt: now, validAt: now, pressure: 1013)])
            try await store.deleteAllForecasts()

            let remaining = try await store.points(issuedAtOrBefore: .distantFuture,
                                                   validIn: everything)
            XCTAssertEqual(remaining.count, 0)
        }
    }

    // MARK: - Durability

    /// Acceptance criterion 2: the request counter survives a relaunch, because it is not a
    /// counter — it is a read over rows that are on disk. Two store instances over one
    /// container stand in for two runs of the process.
    func testTheRequestCountIsReadBackByASecondStoreInstance() async throws {
        let container = try SwiftDataWeatherForecastStore.makeInMemory().modelContainer
        let writer = SwiftDataWeatherForecastStore(modelContainer: container)
        try await writer.save([
            point(issuedAt: now, validAt: now.addingTimeInterval(3600), pressure: 1013),
            point(issuedAt: now.addingTimeInterval(4 * 3600),
                  validAt: now.addingTimeInterval(5 * 3600),
                  pressure: 1011)
        ])

        let reader = SwiftDataWeatherForecastStore(modelContainer: container)
        let issues = try await reader.issueTimes(in: everything)

        XCTAssertEqual(issues.count, 2)
    }

    // MARK: - Helpers

    private var everything: Range<Date> { Date.distantPast..<Date.distantFuture }

    private func makeStores() throws -> [any WeatherForecastStore] {
        [InMemoryWeatherForecastStore(), try SwiftDataWeatherForecastStore.makeInMemory()]
    }

    private func point(issuedAt: Date, validAt: Date, pressure: Double) -> WeatherForecastPoint {
        WeatherForecastPoint(issuedAt: issuedAt,
                             validAt: validAt,
                             meanSeaLevelPressureHPa: pressure,
                             temperatureC: 12)
    }
}
