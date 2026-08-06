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

        let range = await reader.lastRange
        let lower = try XCTUnwrap(range?.lowerBound)
        let span = now.timeIntervalSince(lower)
        XCTAssertEqual(span, 48 * 3600, accuracy: 2)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Records the range of the first kind queried so lookback overrides are observable.
private actor WindowSpyHealthDataReader: HealthDataReader {

    private(set) var lastRange: Range<Date>?

    func requestAuthorization() async throws {}

    func samples(of kind: HealthMetricKind, in range: Range<Date>) async throws -> [HealthSample] {
        if lastRange == nil {
            lastRange = range
        }
        return []
    }
}
