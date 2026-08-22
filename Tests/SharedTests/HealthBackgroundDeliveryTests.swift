import XCTest
@testable import Barosense

final class HealthIngestSignalCoalescerTests: XCTestCase {

    func testBurstOfSignalsProducesOnePerform() async {
        let counter = Counter()
        let coalescer = HealthIngestSignalCoalescer(delayNanoseconds: 50_000_000) {
            await counter.increment()
        }

        await coalescer.signal()
        await coalescer.signal()
        await coalescer.signal()
        await coalescer.waitForPendingWork()

        let value = await counter.value
        XCTAssertEqual(value, 1)
    }

    func testSeparatedSignalsEachPerform() async {
        let counter = Counter()
        let coalescer = HealthIngestSignalCoalescer(delayNanoseconds: 30_000_000) {
            await counter.increment()
        }

        await coalescer.signal()
        await coalescer.waitForPendingWork()
        await coalescer.signal()
        await coalescer.waitForPendingWork()

        let value = await counter.value
        XCTAssertEqual(value, 2)
    }
}

final class HealthSampleRecorderLookbackTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    func testBackgroundLookbackIsNarrowerThanForegroundLookback() {
        XCTAssertLessThan(HealthMetricsWindow.backgroundLookback.seconds,
                          HealthMetricsWindow.refreshLookback.seconds)
        XCTAssertEqual(HealthMetricsWindow.backgroundLookback.seconds, 48 * 3600, accuracy: 0.1)
    }

    func testRefreshLookbackOverrideIsHonoured() async throws {
        let reader = WindowSpyHealthDataReader()
        let recorder = HealthSampleRecorder(reader: reader, log: InMemoryHealthSampleStore())

        _ = try await recorder.refresh(asOf: now, lookback: .backgroundLookback)

        let ranges = await reader.ranges
        let lower = try XCTUnwrap(ranges[.restingHeartRate]?.lowerBound)
        let span = now.timeIntervalSince(lower)
        XCTAssertEqual(span, 48 * 3600, accuracy: 2)
    }

    /// A display-only kind is not read over the caller's lookback. Heart rate is written
    /// every few minutes by a worn watch, so a 7 d foreground refresh would fetch on the
    /// order of 2 000 readings to put one figure on the Now card.
    func testHeartRateIsReadOverItsDisplayWindowNotTheRefreshLookback() async throws {
        let reader = WindowSpyHealthDataReader()
        let recorder = HealthSampleRecorder(reader: reader, log: InMemoryHealthSampleStore())

        _ = try await recorder.refresh(asOf: now, lookback: .refreshLookback)

        let ranges = await reader.ranges
        let heartRateLower = try XCTUnwrap(ranges[.heartRate]?.lowerBound)
        XCTAssertEqual(now.timeIntervalSince(heartRateLower),
                       HealthMetricsWindow.heartRate.seconds,
                       accuracy: 2)

        // The kinds the log keeps are untouched by the cap.
        let restingLower = try XCTUnwrap(ranges[.restingHeartRate]?.lowerBound)
        XCTAssertEqual(now.timeIntervalSince(restingLower), 7 * 24 * 3600, accuracy: 2)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Records the range each kind was queried over, so lookback overrides and per-kind caps
/// are both observable.
///
/// Keyed by kind rather than "the first one asked for": `.heartRate` is read over its own
/// capped window (`HealthMetricKind.readLookbackCap`), so whichever kind happens to come
/// first in `allCases` is not necessarily the caller's lookback.
private actor WindowSpyHealthDataReader: HealthDataReader {

    private(set) var ranges: [HealthMetricKind: Range<Date>] = [:]

    func requestAuthorization() async throws {}

    func samples(of kind: HealthMetricKind, in range: Range<Date>) async throws -> [HealthSample] {
        ranges[kind] = range
        return []
    }
}
