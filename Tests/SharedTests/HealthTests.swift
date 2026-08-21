import XCTest
@testable import Barosense

/// Exercised through `any HealthSampleStore`, not the concrete actor: the contract is what
/// the feature pipeline depends on, and the durable store has to pass the same file.
final class InMemoryHealthSampleStoreTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func date(hoursFromReference hours: Double) -> Date {
        referenceDate.addingTimeInterval(hours * 3600)
    }

    private var historyWindow: Range<Date> {
        date(hoursFromReference: -100)..<date(hoursFromReference: 24)
    }

    private func heartRate(hours: Double, bpm: Double = 60, id: UUID = UUID()) -> HealthSample {
        let instant = date(hoursFromReference: hours)
        return HealthSample(id: id, start: instant, end: instant, value: .restingHeartRateBPM(bpm))
    }

    func testSavedSamplesReadBackAscendingByEnd() async throws {
        let store: any HealthSampleStore = InMemoryHealthSampleStore()

        try await store.save([heartRate(hours: 3, bpm: 58),
                              heartRate(hours: 1, bpm: 61),
                              heartRate(hours: 2, bpm: 59)])

        let read = try await store.samples(of: .restingHeartRate, in: historyWindow)
        XCTAssertEqual(read.map(\.value), [.restingHeartRateBPM(61),
                                           .restingHeartRateBPM(59),
                                           .restingHeartRateBPM(58)])
    }

    func testKindsAreKeptApart() async throws {
        let store: any HealthSampleStore = InMemoryHealthSampleStore()
        let instant = date(hoursFromReference: 1)

        try await store.save([heartRate(hours: 1),
                              HealthSample(id: UUID(), start: instant, end: instant,
                                           value: .oxygenSaturationFraction(0.97))])

        let read = try await store.samples(of: .oxygenSaturation, in: historyWindow)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.value, .oxygenSaturationFraction(0.97))
    }

    func testRereadingTheSameSampleReplacesRatherThanDuplicates() async throws {
        // Refresh windows overlap by design, so the same reading arrives on every pass.
        // Two rows for one reading would double its weight in training.
        let store: any HealthSampleStore = InMemoryHealthSampleStore()
        let id = UUID()

        try await store.save([heartRate(hours: 1, bpm: 60, id: id)])
        try await store.save([heartRate(hours: 1, bpm: 60, id: id)])

        let read = try await store.samples(of: .restingHeartRate, in: historyWindow)
        XCTAssertEqual(read.count, 1)
    }

    func testWindowIsHalfOpenOnEndSoAdjacentWindowsDoNotOverlap() async throws {
        let store: any HealthSampleStore = InMemoryHealthSampleStore()
        let onLowerBound = heartRate(hours: 0)
        let onUpperBound = heartRate(hours: 6)

        try await store.save([onLowerBound, onUpperBound])

        let cutOff = date(hoursFromReference: 6)
        let first = try await store.samples(of: .restingHeartRate, in: referenceDate..<cutOff)
        let second = try await store.samples(of: .restingHeartRate,
                                             in: cutOff..<date(hoursFromReference: 12))

        XCTAssertEqual(first.map(\.id), [onLowerBound.id])
        XCTAssertEqual(second.map(\.id), [onUpperBound.id])
    }

    func testAnIntervalIsWindowedOnItsEndNotItsStart() async throws {
        // A night that began before the window opened but finished inside it was not
        // knowable until it finished, so it belongs to the window that contains its end.
        let store: any HealthSampleStore = InMemoryHealthSampleStore()
        let night = HealthSample(id: UUID(),
                                 start: date(hoursFromReference: -2),
                                 end: date(hoursFromReference: 6),
                                 value: .asleep)

        try await store.save([night])

        let read = try await store.samples(of: .asleep,
                                           in: referenceDate..<date(hoursFromReference: 12))
        XCTAssertEqual(read.map(\.id), [night.id])
    }

    func testRetentionDropsOlderSamplesAndReportsTheCount() async throws {
        let store: any HealthSampleStore = InMemoryHealthSampleStore(
            [heartRate(hours: -50), heartRate(hours: -40), heartRate(hours: 1)])

        let deleted = try await store.deleteSamples(before: date(hoursFromReference: -24))

        XCTAssertEqual(deleted, 2)
        let read = try await store.samples(of: .restingHeartRate, in: historyWindow)
        XCTAssertEqual(read.count, 1)
    }

    func testSavingAnEmptyBatchChangesNothing() async throws {
        let store: any HealthSampleStore = InMemoryHealthSampleStore([heartRate(hours: 1)])

        try await store.save([])

        let read = try await store.samples(of: .restingHeartRate, in: historyWindow)
        XCTAssertEqual(read.count, 1)
    }
}

/// The rules that decide what a number on the Now screen means.
final class HealthMetricsSnapshotTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func date(hoursAgo hours: Double) -> Date {
        now.addingTimeInterval(-hours * 3600)
    }

    private func instant(_ hoursAgo: Double, _ value: HealthMetricValue) -> HealthSample {
        let moment = date(hoursAgo: hoursAgo)
        return HealthSample(id: UUID(), start: moment, end: moment, value: value)
    }

    private func asleep(fromHoursAgo start: Double, toHoursAgo end: Double) -> HealthSample {
        HealthSample(id: UUID(),
                     start: date(hoursAgo: start),
                     end: date(hoursAgo: end),
                     value: .asleep)
    }

    // MARK: - Latest reading

    func testMostRecentReadingWins() {
        let samples = [instant(1, .restingHeartRateBPM(62)),
                       instant(5, .restingHeartRateBPM(70))]

        let snapshot = HealthMetricsSnapshot.make(from: samples, asOf: now)

        XCTAssertEqual(snapshot.restingHeartRateBPM, 62)
    }

    func testAReadingOlderThanItsStalenessBoundIsNotShown() {
        // Resting heart rate lands late, so it is given 48 h; three days old is not "now".
        let snapshot = HealthMetricsSnapshot.make(from: [instant(72, .restingHeartRateBPM(62))],
                                                 asOf: now)

        XCTAssertNil(snapshot.restingHeartRateBPM)
    }

    func testBloodOxygenAndHeartRateHaveSeparateStalenessBounds() {
        // 30 h: inside the heart-rate window, outside the blood-oxygen one.
        let samples = [instant(30, .restingHeartRateBPM(62)),
                       instant(30, .oxygenSaturationFraction(0.97))]

        let snapshot = HealthMetricsSnapshot.make(from: samples, asOf: now)

        XCTAssertEqual(snapshot.restingHeartRateBPM, 62)
        XCTAssertNil(snapshot.oxygenSaturationFraction)
    }

    /// The Now card's figure comes from `.heartRate` — a reading the watch took — and not
    /// from the daily resting aggregate that used to fill it.
    func testThePulseFigureComesFromTheMeasuredRate() {
        let samples = [instant(1, .heartRateBPM(72)),
                       instant(1, .restingHeartRateBPM(58))]

        let snapshot = HealthMetricsSnapshot.make(from: samples, asOf: now)

        XCTAssertEqual(snapshot.heartRateBPM, 72)
        XCTAssertEqual(snapshot.restingHeartRateBPM, 58)
    }

    /// Two families are measured in bpm now. Selection has to be per kind: picking the
    /// newest sample overall and then reading it as a pulse hands the card a resting
    /// aggregate whenever that happens to be the later row — or nothing at all.
    func testANewerRestingAggregateDoesNotDisplaceThePulse() {
        // The pulse is the older of the two, and still inside its own 2 h bound.
        let samples = [instant(1.5, .heartRateBPM(72)),
                       instant(0.5, .restingHeartRateBPM(58))]

        let snapshot = HealthMetricsSnapshot.make(from: samples, asOf: now)

        XCTAssertEqual(snapshot.heartRateBPM, 72)
    }

    /// Two hours, against the resting aggregate's 48. A reading from this morning is not
    /// the current pulse, and a screen headed "now" may not present it as one.
    func testAPulseOlderThanTwoHoursIsNotShown() {
        let samples = [instant(3, .heartRateBPM(72)),
                       instant(3, .restingHeartRateBPM(58))]

        let snapshot = HealthMetricsSnapshot.make(from: samples, asOf: now)

        XCTAssertNil(snapshot.heartRateBPM)
        XCTAssertEqual(snapshot.restingHeartRateBPM, 58)
    }

    func testAnEmptyHistoryProducesAnEmptySnapshot() {
        let snapshot = HealthMetricsSnapshot.make(from: [], asOf: now)

        XCTAssertEqual(snapshot, .empty)
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testOneAvailableMetricIsNotAnEmptySnapshot() {
        let snapshot = HealthMetricsSnapshot.make(from: [instant(1, .restingHeartRateBPM(62))],
                                                 asOf: now)

        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertNil(snapshot.oxygenSaturationFraction)
    }

    // MARK: - Sleep

    func testStagedSegmentsSumToTheWholeNight() {
        let samples = [asleep(fromHoursAgo: 9.5, toHoursAgo: 7),
                       asleep(fromHoursAgo: 7, toHoursAgo: 4),
                       asleep(fromHoursAgo: 4, toHoursAgo: 2.5)]

        let hours = HealthMetricsSnapshot.asleepHours(in: samples, asOf: now)

        XCTAssertEqual(try XCTUnwrap(hours), 7.0, accuracy: 0.001)
    }

    func testTheSameNightFromTwoSourcesIsCountedOnce() {
        // A phone and a watch both write sleep. Summing naively reports a 14-hour night.
        let watch = asleep(fromHoursAgo: 9, toHoursAgo: 2)
        let phone = asleep(fromHoursAgo: 8.5, toHoursAgo: 2.5)

        let hours = HealthMetricsSnapshot.asleepHours(in: [watch, phone], asOf: now)

        XCTAssertEqual(try XCTUnwrap(hours), 7.0, accuracy: 0.001)
    }

    func testPartiallyOverlappingIntervalsExtendRatherThanDouble() {
        let first = asleep(fromHoursAgo: 9, toHoursAgo: 5)
        let second = asleep(fromHoursAgo: 6, toHoursAgo: 3)

        let hours = HealthMetricsSnapshot.asleepHours(in: [first, second], asOf: now)

        XCTAssertEqual(try XCTUnwrap(hours), 6.0, accuracy: 0.001)
    }

    func testSeparateSessionsAreBothCounted() {
        let night = asleep(fromHoursAgo: 12, toHoursAgo: 6)
        let nap = asleep(fromHoursAgo: 3, toHoursAgo: 2)

        let hours = HealthMetricsSnapshot.asleepHours(in: [night, nap], asOf: now)

        XCTAssertEqual(try XCTUnwrap(hours), 7.0, accuracy: 0.001)
    }

    func testAnIntervalStartingBeforeTheWindowStillCountsInFull() {
        // Selection is on the end date, and a night that ended this morning is last
        // night's sleep — not the slice of it inside a trailing 24 hours.
        let samples = [asleep(fromHoursAgo: 25, toHoursAgo: 18)]

        let hours = HealthMetricsSnapshot.asleepHours(in: samples, asOf: now)

        XCTAssertEqual(try XCTUnwrap(hours), 7.0, accuracy: 0.001)
    }

    func testSleepThatEndedBeforeTheWindowIsNotShown() {
        let samples = [asleep(fromHoursAgo: 32, toHoursAgo: 26)]

        XCTAssertNil(HealthMetricsSnapshot.asleepHours(in: samples, asOf: now))
    }

    func testOtherKindsDoNotContributeToSleep() {
        let samples = [instant(1, .restingHeartRateBPM(62)),
                       instant(1, .oxygenSaturationFraction(0.97))]

        XCTAssertNil(HealthMetricsSnapshot.asleepHours(in: samples, asOf: now))
    }
}

/// The boundary gate. A wrong unit reaching the store is the failure this is here to stop:
/// it is silent, it looks like data, and the model would fit to it.
final class HealthSampleGateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    func testBloodOxygenHandedInAsAPercentageIsRejected() {
        // HealthKit's `.percent()` unit yields 0.97. A 97 arriving here means someone
        // converted twice, or not at all.
        let wrongUnit = HealthSample(id: UUID(), start: now, end: now,
                                     value: .oxygenSaturationFraction(97))

        XCTAssertFalse(wrongUnit.isPlausible)
    }

    func testAPlausibleReadingPasses() {
        let sample = HealthSample(id: UUID(), start: now, end: now,
                                  value: .oxygenSaturationFraction(0.97))

        XCTAssertTrue(sample.isPlausible)
    }

    func testAnIntervalEndingBeforeItStartsIsRejected() {
        let backwards = HealthSample(id: UUID(),
                                     start: now,
                                     end: now.addingTimeInterval(-3600),
                                     value: .asleep)

        XCTAssertFalse(backwards.isPlausible)
    }

    func testAnAsleepIntervalLongerThanADayIsRejected() {
        let merged = HealthSample(id: UUID(),
                                  start: now.addingTimeInterval(-30 * 3600),
                                  end: now,
                                  value: .asleep)

        XCTAssertFalse(merged.isPlausible)
    }

    func testAnImplausibleHeartRateIsRejected() {
        let sample = HealthSample(id: UUID(), start: now, end: now,
                                  value: .restingHeartRateBPM(0))

        XCTAssertFalse(sample.isPlausible)
    }
}

/// The one piece of presentation logic worth a test: the split behind the sleep figure the
/// design draws as `7г 20х`. The separator between the two numbers is a translation, so
/// only the numbers are asserted here.
final class HealthMetricsFormattingTests: XCTestCase {

    func testHoursAndMinutesMatchTheDesign() {
        let split = HealthMetricsRow.hoursAndMinutes(7 + 20.0 / 60)
        XCTAssertEqual(split.hours, 7)
        XCTAssertEqual(split.minutes, 20)
    }

    func testMinutesRoundBeforeTheSplitSoSixtyNeverAppears() {
        // 59.6 min must read 1 h 0 min, not 0 h 60 min.
        let split = HealthMetricsRow.hoursAndMinutes(59.6 / 60)
        XCTAssertEqual(split.hours, 1)
        XCTAssertEqual(split.minutes, 0)
    }

    func testAWholeNumberOfHoursShowsZeroMinutes() {
        let split = HealthMetricsRow.hoursAndMinutes(8)
        XCTAssertEqual(split.hours, 8)
        XCTAssertEqual(split.minutes, 0)
    }
}

/// Returns fixed readings, and refuses the kinds it is told to refuse.
///
/// At file scope rather than nested in the test case: it stands in for a whole device, and
/// nesting it two levels deep to reach its own error type is worse than one more top-level
/// name in a test file.
private actor StubHealthDataReader: HealthDataReader {

    enum Failure: Error { case refused }

    private let canned: [HealthMetricKind: [HealthSample]]
    private let failingKinds: Set<HealthMetricKind>

    init(_ canned: [HealthMetricKind: [HealthSample]],
         failing: Set<HealthMetricKind> = []) {
        self.canned = canned
        self.failingKinds = failing
    }

    func requestAuthorization() async throws {}

    func samples(of kind: HealthMetricKind, in range: Range<Date>) async throws -> [HealthSample] {
        if failingKinds.contains(kind) { throw Failure.refused }
        return canned[kind] ?? []
    }
}

/// One pass has to feed the screen and the training log from the same read.
final class HealthSampleRecorderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func instant(_ value: HealthMetricValue) -> HealthSample {
        HealthSample(id: UUID(), start: now, end: now, value: value)
    }

    func testARefreshWritesEverythingItReadIntoTheLog() async throws {
        let store: any HealthSampleStore = InMemoryHealthSampleStore()
        let reader = StubHealthDataReader([.restingHeartRate: [instant(.restingHeartRateBPM(62))],
                                 .oxygenSaturation: [instant(.oxygenSaturationFraction(0.97))]])
        let recorder = HealthSampleRecorder(reader: reader, log: store, gate: HealthIngestGate(isOpen: true))

        let snapshot = try await recorder.refresh(asOf: now)

        XCTAssertEqual(snapshot.restingHeartRateBPM, 62)
        let logged = try await store.samples(of: .restingHeartRate,
                                             in: now.addingTimeInterval(-1)..<now.addingTimeInterval(1))
        XCTAssertEqual(logged.count, 1)
    }

    /// `.heartRate` is read on every refresh and kept out of the log. Nothing in the
    /// feature registry consumes beat-to-beat readings, and a worn watch writes one every
    /// few minutes — see `HealthMetricKind.isLoggedForTraining`.
    func testAMeasuredHeartRateReachesTheScreenButNotTheLog() async throws {
        let store: any HealthSampleStore = InMemoryHealthSampleStore()
        let reader = StubHealthDataReader([.heartRate: [instant(.heartRateBPM(72))],
                                           .restingHeartRate: [instant(.restingHeartRateBPM(58))]])
        let recorder = HealthSampleRecorder(reader: reader, log: store, gate: HealthIngestGate(isOpen: true))

        let snapshot = try await recorder.refresh(asOf: now)

        XCTAssertEqual(snapshot.heartRateBPM, 72)

        let window = now.addingTimeInterval(-1)..<now.addingTimeInterval(1)
        let loggedPulse = try await store.samples(of: .heartRate, in: window)
        XCTAssertTrue(loggedPulse.isEmpty, "beat-to-beat readings must not enter the training log")

        // The kinds the model does consume are unaffected.
        let loggedResting = try await store.samples(of: .restingHeartRate, in: window)
        XCTAssertEqual(loggedResting.count, 1)
    }

    func testOneUnavailableMetricDoesNotSinkTheOthers() async throws {
        // Blood oxygen is absent on most hardware. Losing the whole row over it would be
        // a worse answer than showing the two metrics that are there.
        let reader = StubHealthDataReader([.restingHeartRate: [instant(.restingHeartRateBPM(62))]],
                                failing: [.oxygenSaturation])
        let recorder = HealthSampleRecorder(reader: reader, log: InMemoryHealthSampleStore())

        let snapshot = try await recorder.refresh(asOf: now)

        XCTAssertEqual(snapshot.restingHeartRateBPM, 62)
        XCTAssertNil(snapshot.oxygenSaturationFraction)
    }

    func testEveryMetricFailingSurfacesTheError() async throws {
        let reader = StubHealthDataReader([:], failing: Set(HealthMetricKind.allCases))
        let recorder = HealthSampleRecorder(reader: reader, log: InMemoryHealthSampleStore())

        do {
            _ = try await recorder.refresh(asOf: now)
            XCTFail("a device that refused every read must not look like a quiet day")
        } catch {
            XCTAssertTrue(error is StubHealthDataReader.Failure)
        }
    }

    func testOneFailedMetricWithOtherEmptyReadsIsNotAnError() async throws {
        let reader = StubHealthDataReader([:], failing: [.oxygenSaturation])
        let recorder = HealthSampleRecorder(reader: reader, log: InMemoryHealthSampleStore())

        let snapshot = try await recorder.refresh(asOf: now)

        XCTAssertEqual(snapshot, .empty)
    }

    func testAnEmptyHealthStoreIsNotAnError() async throws {
        let recorder = HealthSampleRecorder(reader: StubHealthDataReader([:]),
                                            log: InMemoryHealthSampleStore())

        let snapshot = try await recorder.refresh(asOf: now)

        XCTAssertEqual(snapshot, .empty)
    }

    func testRepeatedRefreshesDoNotMultiplyTheLog() async throws {
        // Windows overlap on every pass; HealthKit's own identifier is what collapses the
        // repeats onto one row.
        let store: any HealthSampleStore = InMemoryHealthSampleStore()
        let reading = instant(.restingHeartRateBPM(62))
        let recorder = HealthSampleRecorder(reader: StubHealthDataReader([.restingHeartRate: [reading]]),
                                            log: store,
                                            gate: HealthIngestGate(isOpen: true))

        try await recorder.refresh(asOf: now)
        try await recorder.refresh(asOf: now)

        let logged = try await store.samples(of: .restingHeartRate,
                                             in: now.addingTimeInterval(-1)..<now.addingTimeInterval(1))
        XCTAssertEqual(logged.count, 1)
    }
}
