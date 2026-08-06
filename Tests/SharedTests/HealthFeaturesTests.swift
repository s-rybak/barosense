import XCTest
@testable import Barosense

final class HealthFeaturesTests: XCTestCase {

    /// Fixed calendar so "previous day" does not depend on the host's time zone.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Wednesday 2026-02-04 10:00 UTC.
    private var featureInstant: Date {
        calendar.date(from: DateComponents(year: 2026, month: 2, day: 4, hour: 10))!
    }

    private var dayStart: Date {
        calendar.startOfDay(for: featureInstant)
    }

    private var previousDayStart: Date {
        calendar.date(byAdding: .day, value: -1, to: dayStart)!
    }

    private func quantitySample(at date: Date, _ value: HealthMetricValue) -> HealthSample {
        HealthSample(id: UUID(), start: date, end: date, value: value)
    }

    private func asleep(start: Date, end: Date) -> HealthSample {
        HealthSample(id: UUID(), start: start, end: end, value: .asleep)
    }

    // MARK: - Sleep

    func testStagedNightMergesIntoOneSession() {
        let wake = featureInstant.addingTimeInterval(-2 * 3600)
        let samples = [
            asleep(start: wake.addingTimeInterval(-7.5 * 3600), end: wake.addingTimeInterval(-5 * 3600)),
            asleep(start: wake.addingTimeInterval(-5 * 3600), end: wake.addingTimeInterval(-2.5 * 3600)),
            asleep(start: wake.addingTimeInterval(-2.5 * 3600), end: wake)
        ]

        let features = HealthFeatureExtractor.extract(from: samples,
                                                      at: featureInstant,
                                                      calendar: calendar)

        XCTAssertEqual(try XCTUnwrap(features.sleepDurationHours), 7.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(features.hoursSinceWake), 2.0, accuracy: 0.001)
    }

    func testOverlappingSourcesCountOnce() {
        let wake = featureInstant.addingTimeInterval(-1 * 3600)
        let watch = asleep(start: wake.addingTimeInterval(-7 * 3600), end: wake)
        let phone = asleep(start: wake.addingTimeInterval(-6.5 * 3600),
                           end: wake.addingTimeInterval(-0.5 * 3600))

        let features = HealthFeatureExtractor.extract(from: [watch, phone],
                                                      at: featureInstant,
                                                      calendar: calendar)

        XCTAssertEqual(try XCTUnwrap(features.sleepDurationHours), 7.0, accuracy: 0.001)
    }

    func testSleepOlderThan24HoursIsIgnored() {
        let end = featureInstant.addingTimeInterval(-25 * 3600)
        let samples = [asleep(start: end.addingTimeInterval(-7 * 3600), end: end)]

        let features = HealthFeatureExtractor.extract(from: samples,
                                                      at: featureInstant,
                                                      calendar: calendar)

        XCTAssertNil(features.sleepDurationHours)
        XCTAssertNil(features.hoursSinceWake)
    }

    func testFutureSleepDoesNotLeak() {
        let samples = [asleep(start: featureInstant.addingTimeInterval(3600),
                              end: featureInstant.addingTimeInterval(2 * 3600))]

        let features = HealthFeatureExtractor.extract(from: samples,
                                                      at: featureInstant,
                                                      calendar: calendar)

        XCTAssertNil(features.sleepDurationHours)
    }

    func testMostRecentSessionWinsWhenTwoNightsFitTheWindow() {
        let lastWake = featureInstant.addingTimeInterval(-1 * 3600)
        let olderWake = featureInstant.addingTimeInterval(-20 * 3600)
        let samples = [
            asleep(start: olderWake.addingTimeInterval(-6 * 3600), end: olderWake),
            asleep(start: lastWake.addingTimeInterval(-7 * 3600), end: lastWake)
        ]

        let features = HealthFeatureExtractor.extract(from: samples,
                                                      at: featureInstant,
                                                      calendar: calendar)

        XCTAssertEqual(try XCTUnwrap(features.sleepDurationHours), 7.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(features.hoursSinceWake), 1.0, accuracy: 0.001)
    }

    // MARK: - Resting heart rate

    func testUsesPreviousCompletedDay() {
        let yesterday = HealthSample(
            id: UUID(),
            start: previousDayStart,
            end: dayStart,
            value: .restingHeartRateBPM(58)
        )
        let today = HealthSample(
            id: UUID(),
            start: dayStart,
            end: featureInstant.addingTimeInterval(-3600),
            value: .restingHeartRateBPM(70)
        )

        let features = HealthFeatureExtractor.extract(from: [yesterday, today],
                                                      at: featureInstant,
                                                      calendar: calendar)

        XCTAssertEqual(features.restingHeartRateBPM, 58)
    }

    func testLatePublishedYesterdaySampleStillCounts() {
        // Published this morning, but the aggregate covers yesterday — must not be
        // rejected as "today", and must not read as a future leak either.
        let late = HealthSample(
            id: UUID(),
            start: previousDayStart,
            end: dayStart.addingTimeInterval(8 * 3600),
            value: .restingHeartRateBPM(61)
        )

        let features = HealthFeatureExtractor.extract(from: [late],
                                                      at: featureInstant,
                                                      calendar: calendar)

        XCTAssertEqual(features.restingHeartRateBPM, 61)
    }

    func testTodayOnlySampleIsNil() {
        let today = HealthSample(
            id: UUID(),
            start: dayStart,
            end: featureInstant.addingTimeInterval(-1800),
            value: .restingHeartRateBPM(70)
        )

        let features = HealthFeatureExtractor.extract(from: [today],
                                                      at: featureInstant,
                                                      calendar: calendar)

        XCTAssertNil(features.restingHeartRateBPM)
    }

    func testSampleEndingAfterFeatureInstantIsIgnored() {
        let futureEnd = HealthSample(
            id: UUID(),
            start: previousDayStart,
            end: featureInstant.addingTimeInterval(3600),
            value: .restingHeartRateBPM(55)
        )

        let features = HealthFeatureExtractor.extract(from: [futureEnd],
                                                      at: featureInstant,
                                                      calendar: calendar)

        XCTAssertNil(features.restingHeartRateBPM)
    }

    // MARK: - Blood oxygen

    func testMostRecentSaturationWithinLookback() {
        let samples = [
            quantitySample(at: featureInstant.addingTimeInterval(-3 * 3600),
                           .oxygenSaturationFraction(0.96)),
            quantitySample(at: featureInstant.addingTimeInterval(-1 * 3600),
                           .oxygenSaturationFraction(0.98))
        ]

        let features = HealthFeatureExtractor.extract(from: samples,
                                                      at: featureInstant,
                                                      calendar: calendar)

        XCTAssertEqual(features.oxygenSaturationFraction, 0.98)
    }

    func testSaturationOlderThanLookbackIsNil() {
        let samples = [
            quantitySample(at: featureInstant.addingTimeInterval(-30 * 3600),
                           .oxygenSaturationFraction(0.97))
        ]

        let features = HealthFeatureExtractor.extract(from: samples,
                                                      at: featureInstant,
                                                      calendar: calendar)

        XCTAssertNil(features.oxygenSaturationFraction)
    }

    // MARK: - Store-backed extract

    func testExtractFromStoreUsesPersistedSamples() async throws {
        let store: any HealthSampleStore = InMemoryHealthSampleStore()
        let wake = featureInstant.addingTimeInterval(-2 * 3600)
        let samples = [
            asleep(start: wake.addingTimeInterval(-7 * 3600), end: wake),
            HealthSample(id: UUID(),
                         start: previousDayStart,
                         end: dayStart,
                         value: .restingHeartRateBPM(59)),
            quantitySample(at: featureInstant.addingTimeInterval(-1800),
                           .oxygenSaturationFraction(0.97))
        ]
        try await store.save(samples)

        let features = try await HealthFeatureExtractor.extract(from: store,
                                                                at: featureInstant,
                                                                calendar: calendar)

        XCTAssertEqual(try XCTUnwrap(features.sleepDurationHours), 7.0, accuracy: 0.001)
        XCTAssertEqual(features.restingHeartRateBPM, 59)
        XCTAssertEqual(features.oxygenSaturationFraction, 0.97)
    }
}
