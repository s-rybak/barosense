import XCTest
@testable import Barosense

/// The durable half of the WeatherKit switch, and the ledger that rides with it.
///
/// The budget's whole mechanic is that its count survives a relaunch — a counter in memory
/// resets with the process, and a phone that relaunches six times a day would make four
/// requests each time. `WeatherForecastRefresherTests` proves the ledger is *consulted*, on an
/// in-memory double; this proves it is actually on disk.
final class WeatherKitPreferenceStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A suite of its own per test, removed afterwards, so nothing here can read or leave
    /// behind the simulator's real preference. Same shape as `ReminderPreferenceStoreTests`.
    private func makeDefaults(function: String = #function) throws -> UserDefaults {
        let name = "barosense.tests.\(function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }

        return defaults
    }

    private func day(containing instant: Date) -> Range<Date> {
        WeatherRequestBudget().day(containing: instant, calendar: .current)
    }

    // MARK: - The switch

    /// Absence of the key means **on** — §7.2 question 1. `bool(forKey:)` would report `false`
    /// for a key never written and leave every fresh install on the short-range path.
    func testAFreshInstallHasWeatherKitOn() throws {
        let store = UserDefaultsWeatherKitPreferenceStore(defaults: try makeDefaults())

        XCTAssertTrue(store.isWeatherKitEnabled())
        // And the opposite default for the explanation: an install that never wrote this key
        // has genuinely never been shown it.
        XCTAssertFalse(store.hasOfferedWeatherKit())
    }

    // MARK: - The failure ledger

    /// The point of the whole mechanic. A failure recorded by one process has to be visible to
    /// the next one, or a phone relaunched six times a day gets six sets of retries out of a
    /// service that is refusing it.
    func testAFailureSurvivesTheProcessThatRecordedIt() throws {
        let defaults = try makeDefaults()
        UserDefaultsWeatherKitPreferenceStore(defaults: defaults).recordFailedRequest(at: now)

        let afterRelaunch = UserDefaultsWeatherKitPreferenceStore(defaults: defaults)

        XCTAssertEqual(afterRelaunch.failedRequests(in: day(containing: now)), [now])
    }

    /// The budget asks about one local day. A failure from another one must not be counted
    /// against it — otherwise a device that spent yesterday offline would start today with no
    /// allowance at all.
    func testOnlyTheAskedForDayIsReported() throws {
        let store = UserDefaultsWeatherKitPreferenceStore(defaults: try makeDefaults())
        let yesterday = now.addingTimeInterval(-24 * 3600)

        store.recordFailedRequest(at: yesterday)
        store.recordFailedRequest(at: now)

        XCTAssertEqual(store.failedRequests(in: day(containing: now)), [now])
        XCTAssertEqual(store.failedRequests(in: day(containing: yesterday)), [yesterday])
    }

    /// Pruned on write, so a stretch of days offline cannot grow the array without bound. The
    /// horizon is 48 h — one local day plus a DST hour, with room to spare — and anything older
    /// can never be read again anyway.
    func testTheLedgerIsPrunedRatherThanGrowingForever() throws {
        let defaults = try makeDefaults()
        let store = UserDefaultsWeatherKitPreferenceStore(defaults: defaults)

        // Four failures a day for a fortnight of a service that is refusing this build.
        for step in 0..<(14 * 4) {
            store.recordFailedRequest(at: now.addingTimeInterval(-TimeInterval(step) * 6 * 3600))
        }

        let stored = try XCTUnwrap(
            defaults.array(forKey: "barosense.settings.weatherKitFailedRequests") as? [Double]
        )
        // 48 h at one entry per 6 h is eight, plus the one that did the pruning.
        XCTAssertLessThanOrEqual(stored.count, 9)
        XCTAssertFalse(stored.isEmpty)
    }

    /// And the day it matters: four failures inside one day leave the budget with nothing left,
    /// read back through a second instance.
    func testADaysWorthOfFailuresSpendsTheBudget() throws {
        let defaults = try makeDefaults()
        let store = UserDefaultsWeatherKitPreferenceStore(defaults: defaults)
        let budget = WeatherRequestBudget()
        let startOfDay = Calendar.current.startOfDay(for: now)

        for hour in [8, 12, 16, 20] {
            store.recordFailedRequest(at: startOfDay.addingTimeInterval(TimeInterval(hour) * 3600))
        }

        let afterRelaunch = UserDefaultsWeatherKitPreferenceStore(defaults: defaults)
        let spent = afterRelaunch.failedRequests(in: day(containing: now))

        XCTAssertEqual(budget.remainingRequests(on: now, given: spent, calendar: .current), 0)
    }
}
