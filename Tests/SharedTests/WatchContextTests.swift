import XCTest
@testable import Barosense

/// The wire format between the phone and the watch, and the rules around it.
///
/// Two things are asserted here that nothing else can catch: that a hectopascal is still a
/// hectopascal after the round trip, and that a watch one release behind the phone still gets
/// a usable context out of it.
final class WatchContextPayloadTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    /// Fixed identifier. `PressureSample` mints a fresh `UUID` by default, so two calls to
    /// this would differ in a field the wire format is supposed to carry unchanged — and a
    /// round-trip assertion would fail for the one reason that is not a round-trip bug.
    private func snapshot(hPa: Double = 1013.2,
                          trend: PressureTrend = .falling,
                          recent: [PressureTrendPoint] = [],
                          delta: Double? = -2.4) -> PressureDisplaySnapshot {
        PressureDisplaySnapshot(
            sample: PressureSample(id: Self.sampleID,
                                   timestamp: now,
                                   pressure: Pressure(hectopascals: hPa)),
            trend: trend,
            recent: recent,
            deltaHPaPer3h: delta
        )
    }

    private static let sampleID = UUID(uuidString: "00000000-0000-0000-0000-00000000501D")!

    private var seededTags: [WatchTag] {
        WatchTag.offered(from: WellbeingTag.seeds)
    }

    // MARK: - Round trip

    func testAContextSurvivesTheRoundTripUnchanged() throws {
        let original = WatchContext(pressure: snapshot(), tags: seededTags)

        let decoded = try WatchContextPayload.decode(WatchContextPayload.encode(original))

        XCTAssertEqual(decoded, original)
    }

    /// Not a formality: the number the watch prints is this one, and a kPa that gets past the
    /// sensor boundary is a 10× error nothing downstream can catch.
    func testHectopascalsCrossUnchanged() throws {
        let encoded = try WatchContextPayload.encode(WatchContext(pressure: snapshot(hPa: 987.6)))

        let decoded = try WatchContextPayload.decode(encoded)

        XCTAssertEqual(decoded?.pressure?.sample.pressure.hectopascals ?? 0, 987.6, accuracy: 0.0001)
    }

    /// The plotted series and the number beside it come out of the same payload, so a series
    /// that decoded to nothing would be a chart that silently stopped drawing.
    func testTheTrailingSeriesCrossesPointForPoint() throws {
        let points = [
            PressureTrendPoint(timestamp: now.addingTimeInterval(-3600), hectopascals: 1015.5),
            PressureTrendPoint(timestamp: now, hectopascals: 1013.2)
        ]

        let decoded = try WatchContextPayload.decode(
            WatchContextPayload.encode(WatchContext(pressure: snapshot(recent: points)))
        )

        XCTAssertEqual(decoded?.pressure?.recent, points)
    }

    /// The gauge on the detail screen prints this, and its sign is the whole of its meaning.
    func testTheThreeHourDeltaKeepsItsSign() throws {
        let decoded = try WatchContextPayload.decode(
            WatchContextPayload.encode(WatchContext(pressure: snapshot(delta: -4.1)))
        )

        XCTAssertEqual(decoded?.pressure?.deltaHPaPer3h ?? 0, -4.1, accuracy: 0.0001)
    }

    /// Tag identity is what a check-in points at. A seeded slug that came back as a `.user`
    /// UUID would file every watch check-in against a tag the phone has never heard of.
    func testTagIdentityCrossesIntactForBothOrigins() throws {
        let tags = [
            WatchTag(id: .seeded("headache"), name: "Головний біль"),
            WatchTag(id: .user(UUID(uuidString: "00000000-0000-0000-0000-0000000000A7")!),
                     name: "Погода")
        ]

        let decoded = try WatchContextPayload.decode(
            WatchContextPayload.encode(WatchContext(tags: tags))
        )

        XCTAssertEqual(decoded?.tags, tags)
    }

    // MARK: - Version skew

    /// The reason the payload is two keys. A phone that has not published a vocabulary yet —
    /// or one running a build that cannot — must still put a number on the watch.
    func testAContextCarryingOnlyPressureStillDecodes() throws {
        let pressureOnly = try PressureDisplayPayload.encode(snapshot())

        let decoded = try WatchContextPayload.decode(pressureOnly)

        XCTAssertEqual(decoded?.pressure, snapshot())
        XCTAssertEqual(decoded?.tags, [])
    }

    /// And the mirror: the vocabulary is published as soon as the store opens, which on a
    /// device with no barometer is the only half there will ever be.
    func testAContextCarryingOnlyTagsStillDecodes() throws {
        let decoded = try WatchContextPayload.decode(
            WatchContextPayload.encode(WatchContext(tags: seededTags))
        )

        XCTAssertNil(decoded?.pressure)
        XCTAssertEqual(decoded?.tags, seededTags)
    }

    /// A watch running the previous build looks for exactly this key and would show a frozen
    /// number if the phone stopped writing it.
    func testThePressureHalfKeepsTheKeyTheOlderWatchReads() throws {
        let encoded = try WatchContextPayload.encode(WatchContext(pressure: snapshot()))

        XCTAssertNotNil(encoded[PressureDisplayPayload.key])
        XCTAssertEqual(try PressureDisplayPayload.decode(encoded), snapshot())
    }

    /// The two halves must not collide, or a context would overwrite half of itself.
    func testTheTwoKeysAreDistinct() {
        XCTAssertNotEqual(WatchContextPayload.tagsKey, PressureDisplayPayload.key)
    }

    // MARK: - Not ours, and malformed

    /// The session is shared. A context belonging to some other feature lands in the same
    /// delegate callback and must read as "nothing for us", not as a corrupt payload.
    func testAContextWithoutEitherKeyDecodesToNothing() throws {
        XCTAssertNil(try WatchContextPayload.decode(["somethingElse": Data()]))
        XCTAssertNil(try WatchContextPayload.decode([:]))
    }

    func testAKeyHoldingSomethingOtherThanDataIsNotOurs() throws {
        XCTAssertNil(try WatchContextPayload.decode([WatchContextPayload.tagsKey: "a string"]))
    }

    /// Our key with bytes behind it that will not decode is version skew or corruption, and
    /// worth an error — it means the watch is about to keep showing state that has stopped
    /// updating.
    func testTheTagKeyWithUndecodableBytesThrows() {
        let context: [String: Any] = [WatchContextPayload.tagsKey: Data("not json".utf8)]

        XCTAssertThrowsError(try WatchContextPayload.decode(context)) { error in
            XCTAssertEqual(error as? WatchContextError, .malformedPayload)
        }
    }
}

/// Which tags the watch is offered, and in what order.
final class WatchTagOfferingTests: XCTestCase {

    /// The user retired these. Offering them again on a second screen is the one thing
    /// archiving exists to rule out.
    func testArchivedTagsAreNeverOffered() {
        let tags = [
            WellbeingTag(id: .seeded("headache"), name: "Headache"),
            WellbeingTag(id: .seeded("fatigue"), name: "Fatigue", isArchived: true)
        ]

        XCTAssertEqual(WatchTag.offered(from: tags).map(\.id), [.seeded("headache")])
    }

    /// A user who reaches for the third chip on the phone has to find the same tag in the
    /// same place on the watch, so the ordering is asserted rather than assumed.
    func testSeededTagsComeFirstInSeedOrder() {
        let shuffled: [WellbeingTag] = [
            WellbeingTag(id: .seeded("mood"), name: "Mood"),
            WellbeingTag(id: .seeded("headache"), name: "Headache"),
            WellbeingTag(id: .seeded("joints"), name: "Joints")
        ]

        let offered = WatchTag.offered(from: shuffled).map(\.id)

        XCTAssertEqual(offered, [.seeded("headache"), .seeded("joints"), .seeded("mood")])
    }

    func testUserTagsFollowTheSeedsAlphabetically() {
        let tags: [WellbeingTag] = [
            WellbeingTag(id: .user(UUID()), name: "Вітер"),
            WellbeingTag(id: .seeded("headache"), name: "Headache"),
            WellbeingTag(id: .user(UUID()), name: "Автобус")
        ]

        XCTAssertEqual(WatchTag.offered(from: tags).map(\.name),
                       ["Headache", "Автобус", "Вітер"])
    }

    /// An open-ended vocabulary must not turn every context delivery into a forty-row
    /// payload.
    func testTheOfferIsCappedAtWhatAWatchScreenCanHold() {
        let many = (0..<40).map { WellbeingTag(id: .user(UUID()), name: "tag \($0)") }

        XCTAssertEqual(WatchTag.offered(from: many).count, WatchTag.maxOffered)
    }

    /// A rename must not orphan the check-ins already pointing at the tag, so what travels is
    /// the identity and the current text — never a new identifier.
    func testARenamedSeedKeepsItsSlug() {
        let renamed = WellbeingTag(id: .seeded("headache"), name: "Голова")

        XCTAssertEqual(WatchTag.offered(from: [renamed]).first,
                       WatchTag(id: .seeded("headache"), name: "Голова"))
    }
}

/// When a context is worth putting on the air.
///
/// The rule lives in `Shared/` rather than in `WatchBridge` precisely so there is somewhere
/// to assert it from — that type is in the iOS target, which no test target builds.
final class WatchContextPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func context(hPa: Double = 1013,
                         at offset: TimeInterval = 0,
                         tags: [WatchTag] = []) -> WatchContext {
        WatchContext(
            pressure: PressureDisplaySnapshot(
                sample: PressureSample(timestamp: now.addingTimeInterval(offset),
                                       pressure: Pressure(hectopascals: hPa)),
                trend: .steady
            ),
            tags: tags
        )
    }

    func testTheFirstContextOfASessionIsPublished() {
        XCTAssertTrue(WatchContextPolicy.shouldPublish(context(), lastPublished: nil))
    }

    /// The regression this gate exists for. `updateApplicationContext` replaces the whole
    /// slot and the watch keeps that slot across launches, so an empty publish does not read
    /// as "nothing yet" on the other side — it wipes the reading the watch has been showing.
    /// The phone is in exactly this state for about a second on every launch.
    func testAnEmptyContextIsNeverPublished() {
        XCTAssertFalse(WatchContextPolicy.shouldPublish(WatchContext(), lastPublished: nil))
    }

    /// And not on a later call either: "the watch has something, replace it with nothing" is
    /// the worse half of the same mistake.
    func testAnEmptyContextIsNotPublishedOverAFullOne() {
        XCTAssertFalse(WatchContextPolicy.shouldPublish(WatchContext(), lastPublished: context()))
    }

    /// Half a context is not an empty one. A phone whose barometer is unavailable still has a
    /// vocabulary to send, and the watch's check-in form is the poorer without it.
    func testTagsWithoutAReadingAreStillPublished() {
        let vocabulary = WatchContext(tags: WatchTag.offered(from: WellbeingTag.seeds))

        XCTAssertTrue(WatchContextPolicy.shouldPublish(vocabulary, lastPublished: nil))
    }

    /// The other half of that: a reading with no vocabulary yet is what every launch sends
    /// before the stores have opened.
    func testAReadingWithoutTagsIsStillPublished() {
        XCTAssertTrue(WatchContextPolicy.shouldPublish(context(tags: []), lastPublished: nil))
    }

    func testANewReadingIsPublished() {
        XCTAssertTrue(
            WatchContextPolicy.shouldPublish(context(hPa: 1011, at: 900),
                                             lastPublished: context(hPa: 1013))
        )
    }

    /// The vocabulary and the pressure move independently. A rename with no new reading still
    /// has to reach the watch, or its chips keep the old text until the weather changes.
    func testATagChangeAloneIsPublished() {
        let before = context(tags: [WatchTag(id: .seeded("headache"), name: "Headache")])
        let after = context(tags: [WatchTag(id: .seeded("headache"), name: "Голова")])

        XCTAssertTrue(WatchContextPolicy.shouldPublish(after, lastPublished: before))
    }

    /// The identical context means the watch is already showing exactly this. Republishing it
    /// buys nothing and costs a delivery.
    func testRepublishingTheSameContextIsSkipped() {
        let published = context(tags: WatchTag.offered(from: WellbeingTag.seeds))

        XCTAssertFalse(WatchContextPolicy.shouldPublish(published, lastPublished: published))
    }

    /// Two readings the same to the decimal are still two readings — the timestamp differs,
    /// so the watch's age caption would be wrong if this were skipped.
    func testAnUnchangedValueAtANewInstantIsStillPublished() {
        XCTAssertTrue(
            WatchContextPolicy.shouldPublish(context(hPa: 1013, at: 900),
                                             lastPublished: context(hPa: 1013))
        )
    }
}
