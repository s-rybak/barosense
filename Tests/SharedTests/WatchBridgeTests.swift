import XCTest
@testable import Barosense

/// The phone's side of the watch link.
///
/// It holds the two pieces of state that must not be raced or lost — what the watch was last
/// told, and the check-ins that arrived before there was anywhere to put them — and until now
/// neither had a test. The link is injected rather than built from `WCSession`, which is what
/// makes the publish decisions assertable without a paired device.
final class WatchBridgeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func snapshot(hPa: Double = 1013, at offset: TimeInterval = 0) -> PressureDisplaySnapshot {
        PressureDisplaySnapshot(
            sample: PressureSample(timestamp: now.addingTimeInterval(offset),
                                   pressure: Pressure(hectopascals: hPa)),
            trend: .steady
        )
    }

    private func checkIn(at offset: TimeInterval, intensity: Int = 6) -> WatchCheckIn {
        WatchCheckIn(timestamp: now.addingTimeInterval(offset),
                     intensity: CheckInIntensity(clamping: intensity))
    }

    private func everything() -> Range<Date> {
        now.addingTimeInterval(-86_400) ..< now.addingTimeInterval(86_400)
    }

    // MARK: - Phone → watch

    func testAReadingReachesTheWatch() async {
        let link = RecordingContextLink()
        let bridge = WatchBridge(link: link)

        // One instance, published and then compared against: `PressureSample` mints a fresh
        // identifier per value, so two calls to the helper are two different readings.
        let reading = snapshot()
        await bridge.publish(reading)

        let published = await link.published
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.pressure, reading)
    }

    /// The regression the empty gate exists for, at the level the bug actually occurred:
    /// `start()` runs milliseconds into the scene, before the first reading and before the
    /// stores are open, and what it composed was a context with nothing in it. Publishing that
    /// replaces the watch's persisted slot — so the watch stopped showing yesterday's reading
    /// and showed a dash instead.
    func testABridgeWithNothingToSayPutsNothingOnTheAir() async {
        let link = RecordingContextLink()
        let bridge = WatchBridge(link: link)

        await bridge.attach(checkInStore: InMemoryCheckInStore(),
                            tagStore: InMemoryWellbeingTagStore())

        let published = await link.published
        XCTAssertTrue(published.isEmpty)
    }

    /// A phone with no usable barometer — Motion refused, or a simulator — still has a
    /// vocabulary worth sending, and the watch's check-in form has no chips without it.
    func testTheVocabularyIsPublishedEvenWithNoReadingYet() async {
        let link = RecordingContextLink()
        let bridge = WatchBridge(link: link)

        await bridge.attach(checkInStore: InMemoryCheckInStore(),
                            tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds))

        let published = await link.published
        XCTAssertEqual(published.count, 1)
        XCTAssertNil(published.first?.pressure)
        XCTAssertEqual(published.first?.tags, WatchTag.offered(from: WellbeingTag.seeds))
    }

    /// The half that arrives second must not evict the half that arrived first: there is one
    /// slot on the other side, and whoever publishes publishes the whole of it.
    func testAReadingAndTheVocabularyTravelTogether() async {
        let link = RecordingContextLink()
        let bridge = WatchBridge(link: link)

        let reading = snapshot()
        await bridge.publish(reading)
        await bridge.attach(checkInStore: InMemoryCheckInStore(),
                            tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds))

        let latest = await link.published.last
        XCTAssertEqual(latest?.pressure, reading)
        XCTAssertFalse(latest?.tags.isEmpty ?? true)
    }

    func testAnUnchangedReadingIsNotRepublished() async {
        let link = RecordingContextLink()
        let bridge = WatchBridge(link: link)

        let reading = snapshot()
        await bridge.publish(reading)
        await bridge.publish(reading)

        let published = await link.published
        XCTAssertEqual(published.count, 1)
    }

    /// After "delete my data" the vocabulary is dropped and onboarding re-seeds it. The watch
    /// holds its copy in a slot the system persists, so without a republish the user's own tag
    /// names stay on their wrist after they asked for them to be gone.
    func testTheWatchIsToldWhenTheVocabularyIsReplaced() async {
        let link = RecordingContextLink()
        let bridge = WatchBridge(link: link)
        let tags = InMemoryWellbeingTagStore([WellbeingTag(id: .user(UUID()), name: "Long shift")])

        await bridge.attach(checkInStore: InMemoryCheckInStore(), tagStore: tags)
        let beforeErase = await link.published.last
        XCTAssertEqual(beforeErase?.tags.map(\.name), ["Long shift"])

        await tags.deleteAllTags()
        await tags.insertIfAbsent(WellbeingTag.seeds)
        await bridge.refreshTags()

        let latest = await link.published.last
        XCTAssertEqual(latest?.tags, WatchTag.offered(from: WellbeingTag.seeds))
        XCTAssertFalse(latest?.tags.contains { $0.name == "Long shift" } ?? true)
    }

    /// An edit that leaves the offered list identical is not news. Re-reading the store is
    /// cheap; a delivery the watch cannot tell apart from what it is already showing is waste.
    func testAVocabularyRefreshThatChangesNothingIsNotRepublished() async {
        let link = RecordingContextLink()
        let bridge = WatchBridge(link: link)
        let tags = InMemoryWellbeingTagStore(WellbeingTag.seeds)

        await bridge.attach(checkInStore: InMemoryCheckInStore(), tagStore: tags)
        await bridge.refreshTags()

        let published = await link.published
        XCTAssertEqual(published.count, 1)
    }

    // MARK: - Watch → phone

    /// The window this buffer exists for: `transferUserInfo` delivers queued items shortly
    /// after activation, and activation happens while the SwiftData container is still opening.
    func testACheckInThatArrivesBeforeTheStoreIsWrittenWhenItOpens() async {
        let bridge = WatchBridge(link: RecordingContextLink())
        let store = InMemoryCheckInStore()

        await bridge.receive(checkIn(at: -600))
        await bridge.attach(checkInStore: store, tagStore: InMemoryWellbeingTagStore())

        let stored = await store.checkIns(in: everything())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.timestamp, now.addingTimeInterval(-600))
    }

    func testTheOrderCheckInsWereMadeInSurvivesTheBuffer() async {
        let bridge = WatchBridge(link: RecordingContextLink())
        let store = InMemoryCheckInStore()

        for minute in 1...5 {
            await bridge.receive(checkIn(at: TimeInterval(-60 * minute), intensity: minute))
        }
        await bridge.attach(checkInStore: store, tagStore: InMemoryWellbeingTagStore())

        let stored = await store.checkIns(in: everything())
        XCTAssertEqual(stored.map(\.intensity.rawValue), [5, 4, 3, 2, 1])
    }

    /// A store that never opens must not turn a buffer into a leak. The overflow drops the
    /// oldest, because if something has to be lost it should be the report the user is least
    /// likely to still care about.
    func testAStoreThatNeverOpensCannotGrowTheBufferPastItsCeiling() async {
        let bridge = WatchBridge(link: RecordingContextLink())
        let store = InMemoryCheckInStore()
        let overflow = WatchBridge.maxBuffered + 50

        for index in 0..<overflow {
            await bridge.receive(checkIn(at: TimeInterval(index)))
        }
        await bridge.attach(checkInStore: store, tagStore: InMemoryWellbeingTagStore())

        let stored = await store.checkIns(in: everything())
        XCTAssertEqual(stored.count, WatchBridge.maxBuffered)
        // The newest survive: the oldest 50 are the ones dropped.
        XCTAssertEqual(stored.first?.timestamp, now.addingTimeInterval(50))
    }

    /// The same ceiling on the other path. A failed write puts the check-in back on the buffer
    /// so a retry can pick it up, and a store that keeps refusing would otherwise grow it
    /// without bound — the cap has to cover both ways in, not just the one.
    func testAStoreThatKeepsRefusingCannotGrowTheBufferPastItsCeiling() async {
        let bridge = WatchBridge(link: RecordingContextLink())
        let working = InMemoryCheckInStore()
        let overflow = WatchBridge.maxBuffered + 50

        await bridge.attach(checkInStore: FailingCheckInStore(),
                            tagStore: InMemoryWellbeingTagStore())
        for index in 0..<overflow {
            await bridge.receive(checkIn(at: TimeInterval(index)))
        }

        await bridge.attach(checkInStore: working, tagStore: InMemoryWellbeingTagStore())

        let stored = await working.checkIns(in: everything())
        XCTAssertEqual(stored.count, WatchBridge.maxBuffered)
    }

    /// A failed write is a report the user made that the app does not have, so it goes back on
    /// the buffer rather than being logged and forgotten — the retry from the store failure
    /// screen is what picks it up.
    func testARefusedWriteIsKeptForTheRetry() async {
        let bridge = WatchBridge(link: RecordingContextLink())
        let working = InMemoryCheckInStore()

        await bridge.attach(checkInStore: FailingCheckInStore(),
                            tagStore: InMemoryWellbeingTagStore())
        await bridge.receive(checkIn(at: -600))

        await bridge.attach(checkInStore: working, tagStore: InMemoryWellbeingTagStore())

        let stored = await working.checkIns(in: everything())
        XCTAssertEqual(stored.count, 1)
    }

    /// `transferUserInfo` guarantees delivery but not exactly-once semantics. The identifier
    /// is generated on the watch and travels unchanged, so a redelivery updates one row
    /// instead of doubling a training example.
    func testARedeliveredCheckInDoesNotBecomeTwoRows() async {
        let bridge = WatchBridge(link: RecordingContextLink())
        let store = InMemoryCheckInStore()
        let report = checkIn(at: -600)

        await bridge.attach(checkInStore: store, tagStore: InMemoryWellbeingTagStore())
        await bridge.receive(report)
        await bridge.receive(report)

        let stored = await store.checkIns(in: everything())
        XCTAssertEqual(stored.count, 1)
    }
}

// MARK: - Doubles

/// Records what the bridge decided to put on the air.
private actor RecordingContextLink: WatchContextLink {

    private(set) var published: [WatchContext] = []

    func publish(_ context: WatchContext) {
        published.append(context)
    }
}

private struct StoreRefused: Error {}

private struct FailingCheckInStore: CheckInStore {
    func save(_ checkIn: CheckIn) async throws { throw StoreRefused() }
    func checkIns(in range: Range<Date>) async throws -> [CheckIn] { throw StoreRefused() }
    func mostRecentCheckIn(before date: Date) async throws -> CheckIn? { throw StoreRefused() }
    func delete(id: UUID) async throws { throw StoreRefused() }
    func deleteAllCheckIns() async throws { throw StoreRefused() }
}
