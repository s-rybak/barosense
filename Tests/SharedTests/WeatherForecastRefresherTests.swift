import XCTest
@testable import Barosense

/// Every gate in front of a WeatherKit request, checked by counting calls on a double.
///
/// Nothing here touches the network — which is not only a test-hygiene point: WeatherKit does
/// not serve the Simulator at all, so a design that could only be exercised through the real
/// client could not be exercised on this machine.
final class WeatherForecastRefresherTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // swiftlint:disable:next force_unwrapping
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return calendar
    }

    // MARK: - The switches

    /// Acceptance criterion 3. Off means **zero** network calls, not "calls that are discarded".
    func testTheSwitchOffMeansZeroRequests() async {
        let provider = CountingWeatherForecastProvider()
        let refresher = await makeRefresher(provider: provider,
                                      preferences: InMemoryWeatherKitPreferenceStore(
                                          isWeatherKitEnabled: false))

        let outcome = await refresher.refresh(asOf: date(hour: 13))

        XCTAssertEqual(outcome, .switchedOff)
        XCTAssertEqual(provider.forecastCount, 0)
        XCTAssertEqual(provider.historyCount, 0)
    }

    /// The switch ships **on**, so the explanation is what stands between a fresh install and
    /// its first outbound request.
    func testNothingGoesOutBeforeTheTradeHasBeenExplained() async {
        let provider = CountingWeatherForecastProvider()
        let refresher = await makeRefresher(provider: provider,
                                      preferences: InMemoryWeatherKitPreferenceStore(
                                          isWeatherKitEnabled: true,
                                          hasOfferedWeatherKit: false))

        let outcome = await refresher.refresh(asOf: date(hour: 13))

        XCTAssertEqual(outcome, .notYetExplained)
        XCTAssertEqual(provider.forecastCount, 0)
    }

    // MARK: - Location

    /// Acceptance criterion 3a. A revoked grant stops the requests **and leaves the slots
    /// unspent** — burning the day's allowance on calls that cannot run would mean a user who
    /// re-granted at noon got nothing until tomorrow.
    func testARevokedGrantMakesNoRequestAndSpendsNoSlot() async {
        let provider = CountingWeatherForecastProvider()
        let store = InMemoryWeatherForecastStore()
        let access = StubLocationAccessReporter(state: .denied)
        let refresher = await makeRefresher(provider: provider, store: store, access: access)

        let refused = await refresher.refresh(asOf: date(hour: 13))
        XCTAssertEqual(refused, .noLocationAccess)
        XCTAssertEqual(provider.forecastCount, 0)

        // Re-granted a moment later: the noon slot is still there to be spent.
        access.state = .granted(accuracy: .reduced)
        let granted = await refresher.refresh(asOf: date(hour: 13, minute: 1))

        XCTAssertEqual(provider.forecastCount, 1)
        guard case .refreshed = granted else {
            return XCTFail("expected the re-granted pass to fetch, got \(granted)")
        }
    }

    /// Granted, but the first fix has not landed. Not an error — it is the state the local
    /// model exists for.
    func testNoEpochMeansNoRequest() async {
        let provider = CountingWeatherForecastProvider()
        let refresher = await makeRefresher(provider: provider,
                                      epochs: InMemoryPressureLocationEpochStore())

        let outcome = await refresher.refresh(asOf: date(hour: 13))

        XCTAssertEqual(outcome, .noLocation)
        XCTAssertEqual(provider.forecastCount, 0)
    }

    // MARK: - The budget

    /// Acceptance criterion 1, through the whole pass rather than on the arithmetic alone.
    func testFiftyActivationsInADayMakeAtMostFourRequests() async {
        let provider = CountingWeatherForecastProvider()
        let store = InMemoryWeatherForecastStore()
        let refresher = await makeRefresher(provider: provider, store: store, bootstrapped: true)

        for step in 0..<50 {
            let now = date(hour: 7).addingTimeInterval(TimeInterval(step) * 20 * 60)
            await refresher.refresh(asOf: now)
        }

        XCTAssertEqual(provider.forecastCount, 4)
    }

    func testNothingIsFetchedBeforeTheFirstSlot() async {
        let provider = CountingWeatherForecastProvider()
        let refresher = await makeRefresher(provider: provider, bootstrapped: true)

        let outcome = await refresher.refresh(asOf: date(hour: 7))

        XCTAssertEqual(outcome, .notDue)
        XCTAssertEqual(provider.forecastCount, 0)
    }

    // MARK: - Bootstrap

    /// One historical request, once. It is what gives the offset calibrator a week of MSLP to
    /// put beside the barometer history that has been accumulating since install.
    func testTheFirstPassAlsoFetchesAWeekOfHistoryAndOnlyOnce() async {
        let provider = CountingWeatherForecastProvider()
        let store = InMemoryWeatherForecastStore()
        let refresher = await makeRefresher(provider: provider, store: store)

        let first = await refresher.refresh(asOf: date(hour: 9))
        let second = await refresher.refresh(asOf: date(hour: 13))

        XCTAssertEqual(provider.historyCount, 1)
        XCTAssertEqual(provider.forecastCount, 2)
        guard case .refreshed(_, let wasBootstrap) = first, wasBootstrap else {
            return XCTFail("expected the first pass to bootstrap, got \(first)")
        }
        guard case .refreshed(_, let secondBootstrap) = second, !secondBootstrap else {
            return XCTFail("expected the second pass not to bootstrap, got \(second)")
        }
    }

    /// The historical rows must not be readable as *today's* requests. They are stored with
    /// `issuedAt == validAt`, so a window that ran up to `now` would put up to a day of them
    /// inside the budget's own counting window and spend the allowance on rows nobody
    /// requested today.
    func testHistoricalRowsDoNotCountAgainstTodaysAllowance() async throws {
        let store = InMemoryWeatherForecastStore()
        let refresher = await makeRefresher(store: store)

        await refresher.refresh(asOf: date(hour: 9))

        let budget = WeatherRequestBudget()
        let issues = try await store.issueTimes(in: budget.day(containing: date(hour: 9),
                                                               calendar: calendar))
        XCTAssertEqual(issues.count, 1)
    }

    // MARK: - Switching off and back on

    /// Acceptance criterion 4. The archive is the offset calibration's evidence and the skill
    /// record's history; throwing it away on a switch flip would make turning WeatherKit back
    /// on cost a week.
    func testSwitchingOffKeepsTheArchiveAndSwitchingBackOnPaysNoColdStart() async throws {
        let provider = CountingWeatherForecastProvider()
        let store = InMemoryWeatherForecastStore()
        let preferences = InMemoryWeatherKitPreferenceStore()
        let refresher = await makeRefresher(provider: provider,
                                      store: store,
                                      preferences: preferences)

        await refresher.refresh(asOf: date(hour: 9))
        let afterFirstPass = try await store.points(issuedAtOrBefore: date(hour: 9),
                                                    validIn: everything)
        XCTAssertFalse(afterFirstPass.isEmpty)

        preferences.setWeatherKitEnabled(false)
        await refresher.refresh(asOf: date(hour: 13))

        let whileOff = try await store.points(issuedAtOrBefore: date(hour: 13),
                                              validIn: everything)
        XCTAssertEqual(whileOff.count, afterFirstPass.count)

        preferences.setWeatherKitEnabled(true)
        await refresher.refresh(asOf: date(hour: 17))

        // One more forecast, and **no** second bootstrap: the week of history is still there.
        XCTAssertEqual(provider.historyCount, 1)
        XCTAssertEqual(provider.forecastCount, 2)
    }

    // MARK: - Failure

    /// The Simulator's ordinary outcome, and any device without the App ID configured. It has
    /// to be survivable rather than reported.
    func testAServiceRefusalIsAnOrdinaryOutcome() async {
        let refresher = await makeRefresher(provider: FailingWeatherForecastProvider(),
                                      bootstrapped: true)

        let outcome = await refresher.refresh(asOf: date(hour: 13))

        XCTAssertEqual(outcome, .failed)
    }

    // MARK: - Helpers

    private var everything: Range<Date> { Date.distantPast..<Date.distantFuture }

    private func date(hour: Int, minute: Int = 0, dayOffset: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 19 + dayOffset
        components.hour = hour
        components.minute = minute
        // swiftlint:disable:next force_unwrapping
        return calendar.date(from: components)!
    }

    /// `bootstrapped: true` pre-seeds a historical row so the pass under test is the ordinary
    /// one rather than the install-day one.
    private func makeRefresher(provider: any WeatherForecastProviding
                                   = CountingWeatherForecastProvider(),
                               store: any WeatherForecastStore = InMemoryWeatherForecastStore(),
                               epochs: (any PressureLocationEpochStore)? = nil,
                               access: any LocationAccessReporting
                                   = StubLocationAccessReporter(state: .granted(accuracy: .reduced)),
                               preferences: any WeatherKitPreferenceStore
                                   = InMemoryWeatherKitPreferenceStore(),
                               bootstrapped: Bool = false) async -> WeatherForecastRefresher {
        let epochStore = epochs ?? InMemoryPressureLocationEpochStore([
            PressureLocationEpoch(coordinate: GeoCoordinate(latitude: 50.5, longitude: 30.5),
                                  startedAt: date(hour: 8, dayOffset: -30))
        ])

        if bootstrapped {
            // A row valid before today is exactly what the refresher reads as "the bootstrap
            // has already run" — an ordinary forecast never writes one.
            try? await store.save([WeatherForecastPoint(issuedAt: date(hour: 12, dayOffset: -3),
                                                        validAt: date(hour: 12, dayOffset: -3),
                                                        meanSeaLevelPressureHPa: 1010,
                                                        temperatureC: 10)])
        }

        return WeatherForecastRefresher(provider: provider,
                                        store: store,
                                        epochs: epochStore,
                                        access: access,
                                        preferences: preferences,
                                        calendar: calendar)
    }
}

// MARK: - Doubles

/// Answers every request with a small plausible curve, and counts what it was asked for.
private final class CountingWeatherForecastProvider: WeatherForecastProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var _forecastCount = 0
    private var _historyCount = 0

    var forecastCount: Int { lock.withLock { _forecastCount } }
    var historyCount: Int { lock.withLock { _historyCount } }

    func forecast(for coordinate: GeoCoordinate, asOf now: Date) async throws -> WeatherForecastIssue {
        lock.withLock { _forecastCount += 1 }

        let points = (0..<24).map { hour in
            WeatherForecastPoint(issuedAt: now,
                                 validAt: now.addingTimeInterval(TimeInterval(hour) * 3600),
                                 meanSeaLevelPressureHPa: 1013 - Double(hour) * 0.2,
                                 temperatureC: 12)
        }
        return WeatherForecastIssue(issuedAt: now, points: points)
    }

    func history(for coordinate: GeoCoordinate, in range: Range<Date>) async throws -> [WeatherObservation] {
        lock.withLock { _historyCount += 1 }

        var observations: [WeatherObservation] = []
        var instant = range.lowerBound
        while instant < range.upperBound {
            observations.append(WeatherObservation(validAt: instant,
                                                   meanSeaLevelPressureHPa: 1012,
                                                   temperatureC: 9))
            instant = instant.addingTimeInterval(3600)
        }
        return observations
    }
}

private struct ServiceRefused: Error {}

/// What the Simulator does, and any build without a configured App ID.
private struct FailingWeatherForecastProvider: WeatherForecastProviding {

    func forecast(for coordinate: GeoCoordinate, asOf now: Date) async throws -> WeatherForecastIssue {
        throw WeatherForecastError.serviceRefused(underlying: ServiceRefused())
    }

    func history(for coordinate: GeoCoordinate, in range: Range<Date>) async throws -> [WeatherObservation] {
        throw WeatherForecastError.serviceRefused(underlying: ServiceRefused())
    }
}
