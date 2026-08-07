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

    // MARK: - Ingest

    func testIngestedSamplesKeepTheIdentifierTheSenderGaveThem() async throws {
        let log = InMemoryPressureSampleStore()
        let recorder = PressureSampleRecorder(source: UnavailablePressureSource(), log: log)
        let id = UUID()
        let sample = PressureSample(id: id, timestamp: now, pressure: Pressure(hectopascals: 1012))

        try await recorder.ingest([sample])
        try await recorder.ingest([sample])

        let stored = try await log.samples(in: wholeHistory)
        XCTAssertEqual(stored.count, 1, "a redelivered reading must collapse onto one row")
        XCTAssertEqual(stored.first?.id, id)
    }

    func testIngestDropsImplausibleRowsAndKeepsTheRest() async throws {
        let log = InMemoryPressureSampleStore()
        let recorder = PressureSampleRecorder(source: UnavailablePressureSource(), log: log)

        try await recorder.ingest([
            PressureSample(timestamp: now, pressure: Pressure(hectopascals: 1012)),
            PressureSample(timestamp: now.addingTimeInterval(60), pressure: Pressure(hectopascals: 101.3))
        ])

        let stored = try await log.samples(in: wholeHistory)
        XCTAssertEqual(stored.map(\.pressure.hectopascals), [1012])
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

    func currentPressure() async throws -> Pressure {
        throw PressureSourceError.barometerUnavailable
    }
}
