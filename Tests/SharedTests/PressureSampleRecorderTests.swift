import XCTest
@testable import Barosense

/// Sampling policy and the sensor boundary, with a stub in place of `CMAltimeter`.
final class PressureSampleRecorderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private var wholeHistory: Range<Date> {
        now.addingTimeInterval(-100 * 3600)..<now.addingTimeInterval(100 * 3600)
    }

    // MARK: - Recording

    func testARecordedReadingLandsInTheLog() async throws {
        let log = InMemoryPressureSampleStore()
        let recorder = PressureSampleRecorder(source: StubPressureSource(hectopascals: 1013.2), log: log)

        let sample = try await recorder.record(asOf: now)

        XCTAssertEqual(sample?.pressure.hectopascals, 1013.2)
        let stored = try await log.samples(in: wholeHistory)
        XCTAssertEqual(stored.map(\.pressure.hectopascals), [1013.2])
    }

    /// The classic unit bug: a kPa value arriving where hPa is expected. It must be rejected
    /// loudly rather than stored 10× off, where nothing downstream could ever notice.
    func testAKilopascalValuedReadingIsRejectedRatherThanStored() async throws {
        let log = InMemoryPressureSampleStore()
        let recorder = PressureSampleRecorder(source: StubPressureSource(hectopascals: 101.325), log: log)

        do {
            _ = try await recorder.record(asOf: now)
            XCTFail("an implausible reading must not be stored")
        } catch PressureSourceError.implausibleReading {
            // Expected.
        }

        let stored = try await log.samples(in: wholeHistory)
        XCTAssertTrue(stored.isEmpty)
    }

    func testASensorFailurePropagatesAndStoresNothing() async throws {
        let log = InMemoryPressureSampleStore()
        let recorder = PressureSampleRecorder(source: FailingPressureSource(), log: log)

        do {
            _ = try await recorder.record(asOf: now)
            XCTFail("a sensor failure must reach the caller")
        } catch PressureSourceError.barometerUnavailable {
            // Expected.
        }

        let stored = try await log.samples(in: wholeHistory)
        XCTAssertTrue(stored.isEmpty)
    }

    // MARK: - Rate limit

    /// Flipping in and out of the app must not turn into sensor time.
    func testASecondReadingInsideTheMinimumIntervalIsSkipped() async throws {
        let source = StubPressureSource(hectopascals: 1013)
        let log = InMemoryPressureSampleStore()
        let recorder = PressureSampleRecorder(source: source, log: log, minimumInterval: 600)

        _ = try await recorder.record(asOf: now)
        let skipped = try await recorder.record(asOf: now.addingTimeInterval(300))

        XCTAssertNil(skipped, "a skip is an ordinary outcome, not a failure")
        let readCount = await source.readCount
        XCTAssertEqual(readCount, 1, "the barometer must not have been started a second time")
        let stored = try await log.samples(in: wholeHistory)
        XCTAssertEqual(stored.count, 1)
    }

    func testAReadingPastTheMinimumIntervalIsTaken() async throws {
        let source = StubPressureSource(hectopascals: 1013)
        let recorder = PressureSampleRecorder(source: source,
                                              log: InMemoryPressureSampleStore(),
                                              minimumInterval: 600)

        _ = try await recorder.record(asOf: now)
        let second = try await recorder.record(asOf: now.addingTimeInterval(601))

        XCTAssertNotNil(second)
        let readCount = await source.readCount
        XCTAssertEqual(readCount, 2)
    }

    /// The floor, asked rather than discovered. The caller resolves the location epoch before
    /// recording, and resolving it in the foreground powers the radio — so an activation the
    /// floor is about to refuse must be knowable *before* paying for it. Twenty activations in
    /// an hour used to mean twenty fixes and one row.
    func testTheRateLimitCanBeAskedBeforeItIsSpent() async throws {
        let recorder = PressureSampleRecorder(source: StubPressureSource(hectopascals: 1013),
                                              log: InMemoryPressureSampleStore(),
                                              minimumInterval: 600)

        let beforeAnything = await recorder.admitsReading(asOf: now)
        _ = try await recorder.record(asOf: now)
        let insideTheFloor = await recorder.admitsReading(asOf: now.addingTimeInterval(300))
        let pastTheFloor = await recorder.admitsReading(asOf: now.addingTimeInterval(601))

        XCTAssertTrue(beforeAnything, "a fresh process has nothing to wait for")
        XCTAssertFalse(insideTheFloor)
        XCTAssertTrue(pastTheFloor)
    }

    /// Advisory, not the gate. A caller that never asks must still be rate-limited.
    func testTheRateLimitStillHoldsForACallerThatNeverAsks() async throws {
        let source = StubPressureSource(hectopascals: 1013)
        let recorder = PressureSampleRecorder(source: source,
                                              log: InMemoryPressureSampleStore(),
                                              minimumInterval: 600)

        _ = try await recorder.record(asOf: now)
        let skipped = try await recorder.record(asOf: now.addingTimeInterval(300))

        XCTAssertNil(skipped)
        let readCount = await source.readCount
        XCTAssertEqual(readCount, 1)
    }

    /// A rejected reading must not consume the rate-limit slot — otherwise one bad sample
    /// blanks out the next ten minutes of history as well.
    func testARejectedReadingDoesNotStartTheRateLimit() async throws {
        let source = StubPressureSource(hectopascals: 101.325)
        let recorder = PressureSampleRecorder(source: source,
                                              log: InMemoryPressureSampleStore(),
                                              minimumInterval: 600)

        _ = try? await recorder.record(asOf: now)
        await source.setValue(1013)
        let second = try await recorder.record(asOf: now.addingTimeInterval(1))

        XCTAssertEqual(second?.pressure.hectopascals, 1013)
    }

    // MARK: - Retention

    /// Five years, and five *calendar* years — the horizon has to land on the same date every
    /// year rather than creeping forward by a day per leap year.
    func testTheRetentionHorizonIsFiveCalendarYearsBack() {
        let cutoff = PressureRetentionPolicy.cutoff(asOf: now)
        let years = Calendar.current.dateComponents([.year], from: cutoff, to: now).year

        XCTAssertEqual(PressureRetentionPolicy.maximumHistoryYears, 5)
        XCTAssertEqual(years, PressureRetentionPolicy.maximumHistoryYears)
    }

    /// A recorded reading carries the retention pass with it. This is the only thing in the
    /// app that deletes a pressure row, so if it stops happening the log grows without bound
    /// and nothing anywhere complains.
    func testRecordingDropsRowsPastTheHorizon() async throws {
        let expired = PressureSample(timestamp: now.addingTimeInterval(-6 * 365 * 24 * 3600),
                                     pressure: Pressure(hectopascals: 1005))
        let kept = PressureSample(timestamp: now.addingTimeInterval(-30 * 24 * 3600),
                                  pressure: Pressure(hectopascals: 1018))
        let log = InMemoryPressureSampleStore([expired, kept])
        let recorder = PressureSampleRecorder(source: StubPressureSource(hectopascals: 1013), log: log)

        _ = try await recorder.record(asOf: now)

        let stored = try await log.samples(in: Date.distantPast..<Date.distantFuture)
        XCTAssertEqual(stored.map(\.pressure.hectopascals), [1018, 1013],
                       "the six-year-old row goes, the month-old one stays")
    }

    /// The horizon moves by one day per day, so the pass runs daily and no more often. A
    /// retention query on every reading would be up to 96 index scans a day that match
    /// nothing.
    func testRetentionRunsAtMostOncePerDay() async throws {
        let log = CountingPressureSampleStore()
        let recorder = PressureSampleRecorder(source: StubPressureSource(hectopascals: 1013),
                                              log: log,
                                              minimumInterval: 600)

        _ = try await recorder.record(asOf: now)
        _ = try await recorder.record(asOf: now.addingTimeInterval(3600))
        let withinTheDay = await log.deleteCallCount

        _ = try await recorder.record(asOf: now.addingTimeInterval(25 * 3600))
        let afterADay = await log.deleteCallCount

        XCTAssertEqual(withinTheDay, 1, "two readings an hour apart, one retention pass")
        XCTAssertEqual(afterADay, 2, "the horizon has moved, so the pass runs again")
    }

    /// Retention is housekeeping and runs after the write. A store that cannot delete must
    /// not cost the caller the reading it just took — that would turn a disk-space problem
    /// into a lost measurement.
    func testAFailedRetentionPassDoesNotFailTheReading() async throws {
        let recorder = PressureSampleRecorder(source: StubPressureSource(hectopascals: 1013),
                                              log: UndeletablePressureSampleStore())

        let sample = try await recorder.record(asOf: now)

        XCTAssertEqual(sample?.pressure.hectopascals, 1013)
    }

    // MARK: - Policy

    /// The chart buckets on a grid derived from this number, and a bucket finer than the
    /// sampling floor averages nothing. If the floor is ever loosened, `bucketSeconds` has to
    /// move with it or the narrow ranges start drawing one point per bucket forever.
    func testTheFinestChartBucketIsNotFinerThanTheSamplingFloor() {
        let finestBucket = PressureChartRange.allCases.map(\.bucketSeconds).min()

        XCTAssertEqual(finestBucket, PressureSamplingPolicy.minimumIntervalSeconds)
    }

    // MARK: - Reads

    func testTrailingWindowReturnsOnlyRecentSamplesAscending() async throws {
        let log = InMemoryPressureSampleStore([
            PressureSample(timestamp: now.addingTimeInterval(-8 * 3600), pressure: Pressure(hectopascals: 1020)),
            PressureSample(timestamp: now.addingTimeInterval(-2 * 3600), pressure: Pressure(hectopascals: 1015)),
            PressureSample(timestamp: now.addingTimeInterval(-3600), pressure: Pressure(hectopascals: 1014))
        ])
        let recorder = PressureSampleRecorder(source: UnavailablePressureSource(), log: log)

        let window = try await recorder.samples(trailing: 6 * 3600, asOf: now)

        XCTAssertEqual(window.map(\.pressure.hectopascals), [1015, 1014])
    }

    /// The newest reading is the one the card is about to print; a half-open window that
    /// excluded `now` would drop it every time.
    func testTrailingWindowIncludesASampleTimestampedExactlyNow() async throws {
        let log = InMemoryPressureSampleStore([
            PressureSample(timestamp: now, pressure: Pressure(hectopascals: 1011))
        ])
        let recorder = PressureSampleRecorder(source: UnavailablePressureSource(), log: log)

        let window = try await recorder.samples(trailing: 3600, asOf: now)

        XCTAssertEqual(window.count, 1)
    }
}

// MARK: - Doubles

/// Returns a fixed reading and counts how often the sensor was asked for one, which is what
/// the rate-limit assertions are really about.
private actor StubPressureSource: PressureSource {

    private(set) var readCount = 0
    private var hectopascals: Double

    init(hectopascals: Double) {
        self.hectopascals = hectopascals
    }

    nonisolated var isAvailable: Bool { true }

    /// Granted, so the controller's launch gate is not what these tests are exercising.
    nonisolated var access: BarometerAccessState { .granted }

    func setValue(_ newValue: Double) {
        hectopascals = newValue
    }

    func currentPressure() async throws -> Pressure {
        readCount += 1
        return Pressure(hectopascals: hectopascals)
    }
}

private struct FailingPressureSource: PressureSource {

    var isAvailable: Bool { true }

    var access: BarometerAccessState { .granted }

    func currentPressure() async throws -> Pressure {
        throw PressureSourceError.barometerUnavailable
    }
}

/// Counts retention passes. How often the store is *asked* to prune is the assertion, and no
/// amount of inspecting its contents can show that.
private actor CountingPressureSampleStore: PressureSampleStore {

    private(set) var deleteCallCount = 0
    private var storage: [PressureSample] = []

    func save(_ samples: [PressureSample]) {
        storage.append(contentsOf: samples)
    }

    func samples(in range: Range<Date>) -> [PressureSample] {
        storage
            .filter { range.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    @discardableResult
    func deleteSamples(before date: Date) -> Int {
        deleteCallCount += 1
        return 0
    }
}

/// Stores readings, refuses to delete them. Stands in for a store whose retention query
/// fails while the write path is perfectly healthy.
private actor UndeletablePressureSampleStore: PressureSampleStore {

    private struct DeleteRefused: Error {}

    private var storage: [PressureSample] = []

    func save(_ samples: [PressureSample]) {
        storage.append(contentsOf: samples)
    }

    func samples(in range: Range<Date>) -> [PressureSample] {
        storage.filter { range.contains($0.timestamp) }
    }

    @discardableResult
    func deleteSamples(before date: Date) throws -> Int {
        throw DeleteRefused()
    }
}
