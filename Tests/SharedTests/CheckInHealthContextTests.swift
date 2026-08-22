import XCTest
@testable import Barosense

/// The health stamp a check-in carries: pulse, blood oxygen, hours of sleep.
///
/// Two properties are load-bearing and both are asserted here — that an implausible reading
/// is dropped field by field rather than stored or taken down with its neighbours, and that
/// "the app looked and found nothing" stays distinguishable from "nothing looked".
@MainActor
final class CheckInHealthContextTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - Plausibility

    func testAReadingOffItsScaleIsDroppedWithoutTakingTheOthersWithIt() {
        // 97 is a percentage where a fraction belongs — the unit mix-up the gate exists for.
        let context = CheckInHealthContext(heartRateBPM: 68,
                                           oxygenSaturationFraction: 97,
                                           asleepHours: 7.5)

        XCTAssertNil(context.oxygenSaturationFraction)
        XCTAssertEqual(context.heartRateBPM, 68)
        XCTAssertEqual(context.asleepHours, 7.5)
    }

    func testAPulseNobodyCouldHaveIsDropped() {
        XCTAssertNil(CheckInHealthContext(heartRateBPM: 0).heartRateBPM)
        XCTAssertNil(CheckInHealthContext(heartRateBPM: 400).heartRateBPM)
        XCTAssertEqual(CheckInHealthContext(heartRateBPM: 52).heartRateBPM, 52)
    }

    func testSleepBeyondADayIsAMergeArtefactAndIsDropped() {
        // The union counts intervals selected on their end, so two staged nights from two
        // sources can add past 24 h. That is not a night anybody slept.
        XCTAssertNil(CheckInHealthContext(asleepHours: 30).asleepHours)
        XCTAssertNil(CheckInHealthContext(asleepHours: -1).asleepHours)
        XCTAssertEqual(CheckInHealthContext(asleepHours: 24).asleepHours, 24)
        XCTAssertEqual(CheckInHealthContext(asleepHours: 0).asleepHours, 0)
    }

    // MARK: - Storage format

    func testAnAbsentFieldDecodesAsNothingRatherThanFailingTheStamp() throws {
        // What a payload written before a field existed looks like. Losing the whole stamp
        // over a missing key would lose the two fields that were there.
        let decoded = try JSONDecoder().decode(CheckInHealthContext.self,
                                               from: Data("{\"heartRateBPM\":71}".utf8))

        XCTAssertEqual(decoded.heartRateBPM, 71)
        XCTAssertNil(decoded.oxygenSaturationFraction)
        XCTAssertNil(decoded.asleepHours)
    }

    func testDecodingPassesTheSameGateAsAReadingMeasuredHere() throws {
        // The decoder is routed through the initialiser rather than synthesised, so a stored
        // percentage cannot enter through the back door.
        let decoded = try JSONDecoder().decode(
            CheckInHealthContext.self,
            from: Data("{\"oxygenSaturationFraction\":97}".utf8)
        )

        XCTAssertTrue(decoded.isEmpty)
    }

    func testTheStampSurvivesACodableRoundTripOnItsCheckIn() throws {
        let original = CheckIn(timestamp: referenceDate,
                               intensity: CheckInIntensity(clamping: 4),
                               health: CheckInHealthContext(heartRateBPM: 68,
                                                            oxygenSaturationFraction: 0.97,
                                                            asleepHours: 7.5))

        let decoded = try JSONDecoder().decode(CheckIn.self,
                                               from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.health?.heartRateBPM, 68)
        XCTAssertEqual(decoded.health?.oxygenSaturationFraction, 0.97)
        XCTAssertEqual(decoded.health?.asleepHours, 7.5)
    }

    func testACheckInWrittenWithoutAStampStillDecodes() throws {
        // The watch→phone payload this format is waiting for may be written by a build that
        // does not read Health at all. An absent stamp is a state, not a decode failure.
        let original = CheckIn(timestamp: referenceDate, intensity: CheckInIntensity(clamping: 9))

        let decoded = try JSONDecoder().decode(CheckIn.self,
                                               from: JSONEncoder().encode(original))

        XCTAssertNil(decoded.health)
    }

    func testNothingLookedIsNotTheSameAsLookedAndFoundNothing() {
        // The distinction a coverage count over the history depends on. If these compared
        // equal, "the user has no watch" and "this row predates the stamp" would be one
        // number.
        let unstamped = CheckIn(timestamp: referenceDate,
                                intensity: CheckInIntensity(clamping: 5))
        let stampedEmpty = CheckIn(id: unstamped.id,
                                   timestamp: referenceDate,
                                   intensity: CheckInIntensity(clamping: 5),
                                   health: .empty)

        XCTAssertNil(unstamped.health)
        XCTAssertEqual(stampedEmpty.health, .empty)
        XCTAssertNotEqual(unstamped, stampedEmpty)
    }

    // MARK: - Built from a Now-screen snapshot

    func testTheStampKeepsTheMeasuredPulseAndDropsTheDailyAggregate() {
        // `restingHeartRateBPM` is a daily aggregate published hours after the day it covers.
        // Stamping it at the check-in's hour would summarise a window running past the
        // check-in's own timestamp — the look-ahead §2.3 forbids.
        let snapshot = HealthMetricsSnapshot(heartRateBPM: 88,
                                             restingHeartRateBPM: 61,
                                             oxygenSaturationFraction: 0.96,
                                             asleepHours: 6.25)

        let context = CheckInHealthContext(snapshot: snapshot)

        XCTAssertEqual(context.heartRateBPM, 88)
        XCTAssertEqual(context.oxygenSaturationFraction, 0.96)
        XCTAssertEqual(context.asleepHours, 6.25)
    }

    func testAnEmptySnapshotMakesAnEmptyStamp() {
        XCTAssertTrue(CheckInHealthContext(snapshot: .empty).isEmpty)
    }

    // MARK: - Stamping on save

    func testASavedCheckInCarriesWhatHealthReturned() async throws {
        let store = InMemoryCheckInStore()
        let health = RecordingHealthContext(CheckInHealthContext(heartRateBPM: 74,
                                                                 oxygenSaturationFraction: 0.98,
                                                                 asleepHours: 8))
        let model = makeModel(store: store, health: health)

        await model.load()
        await save(model)

        let stored = try await store.checkIns(in: Date.distantPast..<Date.distantFuture)
        XCTAssertEqual(stored.first?.health?.heartRateBPM, 74)
        XCTAssertEqual(stored.first?.health?.oxygenSaturationFraction, 0.98)
        XCTAssertEqual(stored.first?.health?.asleepHours, 8)
    }

    func testAReadThatCameBackWithNothingStillStampsTheRow() async throws {
        let store = InMemoryCheckInStore()
        let model = makeModel(store: store, health: RecordingHealthContext(.empty))

        await model.load()
        await save(model)

        let stored = try await store.checkIns(in: Date.distantPast..<Date.distantFuture)
        // Not `nil`: the app looked. Every reason it came back empty — no watch, no grant,
        // an empty Health store — is indistinguishable from the others by design, and none
        // of them is "this row was never stamped".
        XCTAssertEqual(stored.first?.health, .empty)
    }

    func testTheStampIsReadOnceForTheSheetAndAtItsOwnClock() async throws {
        let health = RecordingHealthContext(CheckInHealthContext(heartRateBPM: 74))
        let model = makeModel(health: health)

        // `.task` re-runs whenever the view is rebuilt. A second read would stamp the row at
        // a later instant than the one the sheet was opened at, and cost a second four-query
        // round trip for it.
        await model.load()
        await model.load()
        await save(model)

        let instants = await health.requestedInstants
        XCTAssertEqual(instants, [referenceDate])
    }

    func testACheckInSavedBeforeTheSheetLoadedIsStillStamped() async throws {
        let store = InMemoryCheckInStore()
        let model = makeModel(store: store,
                              health: RecordingHealthContext(CheckInHealthContext(heartRateBPM: 74)))

        // No `load()`: the save path starts the read itself rather than stamping nothing.
        await save(model)

        let stored = try await store.checkIns(in: Date.distantPast..<Date.distantFuture)
        XCTAssertEqual(stored.first?.health?.heartRateBPM, 74)
    }

    // MARK: - Helpers

    /// Fulfilled by the model's completion callback. `LogModel.save()` is fire-and-forget —
    /// the sheet has dismissed by the time the store answers — so this is the only thing a
    /// test can wait on.
    private lazy var saved = expectation(description: "check-in written")

    private func makeModel(store: any CheckInStore = InMemoryCheckInStore(),
                           health: any CheckInHealthContextProviding) -> LogModel {
        LogModel(checkInStore: store,
                 tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                 health: health,
                 now: { [referenceDate] in referenceDate },
                 onSaved: { [saved] in saved.fulfill() })
    }

    private func save(_ model: LogModel) async {
        model.save()
        await fulfillment(of: [saved], timeout: 2)
    }
}

/// A stand-in Health read: answers with a fixed stamp and remembers what it was asked for.
///
/// An actor rather than a class with a counter, because the protocol is `Sendable` and the
/// project builds with complete strict concurrency.
private actor RecordingHealthContext: CheckInHealthContextProviding {

    private(set) var requestedInstants: [Date] = []

    private let context: CheckInHealthContext

    init(_ context: CheckInHealthContext) {
        self.context = context
    }

    func healthContext(asOf now: Date) async -> CheckInHealthContext {
        requestedInstants.append(now)
        return context
    }
}
