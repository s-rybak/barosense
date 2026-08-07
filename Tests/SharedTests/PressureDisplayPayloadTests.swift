import XCTest
@testable import Barosense

/// The wire format between the phone and the watch. A hectopascal that becomes a kilopascal
/// in transit is a 10× error nothing downstream can catch, so the round trip is asserted on
/// the value and not just on "it decoded".
final class PressureDisplayPayloadTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func snapshot(hPa: Double = 1013.2, trend: PressureTrend = .falling) -> PressureDisplaySnapshot {
        PressureDisplaySnapshot(
            sample: PressureSample(timestamp: now, pressure: Pressure(hectopascals: hPa)),
            trend: trend
        )
    }

    func testASnapshotSurvivesTheRoundTripUnchanged() throws {
        let original = snapshot()

        let decoded = try PressureDisplayPayload.decode(PressureDisplayPayload.encode(original))

        XCTAssertEqual(decoded, original)
    }

    /// Not a formality: `PressureSample` carries a `Double` and a `Date`, and the number the
    /// watch prints is this one. Asserted separately from equality so a failure names the
    /// unit rather than "structs differ".
    func testHectopascalsCrossUnchanged() throws {
        let decoded = try PressureDisplayPayload.decode(PressureDisplayPayload.encode(snapshot(hPa: 987.6)))

        XCTAssertEqual(decoded?.sample.pressure.hectopascals ?? 0, 987.6, accuracy: 0.0001)
    }

    /// The trend is the one field with a hand-written raw value. A case renamed on one side
    /// of a staggered update would otherwise silently arrive as a decode failure.
    func testEveryTrendCaseCrossesIntact() throws {
        for trend in [PressureTrend.rising, .falling, .steady, .unknown] {
            let decoded = try PressureDisplayPayload.decode(
                PressureDisplayPayload.encode(snapshot(trend: trend))
            )
            XCTAssertEqual(decoded?.trend, trend)
        }
    }

    /// The session is shared. A context belonging to some other feature lands in the same
    /// delegate callback and must read as "nothing for us", not as a corrupt payload.
    func testAContextWithoutOurKeyDecodesToNothing() throws {
        XCTAssertNil(try PressureDisplayPayload.decode(["somethingElse": Data()]))
        XCTAssertNil(try PressureDisplayPayload.decode([:]))
    }

    func testAKeyHoldingSomethingOtherThanDataIsNotOurs() throws {
        XCTAssertNil(try PressureDisplayPayload.decode([PressureDisplayPayload.key: "a string"]))
    }

    /// Our key with bytes behind it that will not decode is version skew or corruption, and
    /// the one case worth an error — it means the watch is about to keep showing a number
    /// that has stopped updating.
    func testOurKeyWithUndecodableBytesThrows() {
        let context: [String: Any] = [PressureDisplayPayload.key: Data("not json".utf8)]

        XCTAssertThrowsError(try PressureDisplayPayload.decode(context)) { error in
            XCTAssertEqual(error as? PressureDisplayError, .malformedPayload)
        }
    }

    /// The key changed direction with the payload. A watch still running the build that sent
    /// samples to the phone must not read the new context as history to ingest.
    func testTheKeyIsNotTheOneTheOldWatchToPhonePayloadUsed() {
        XCTAssertNotEqual(PressureDisplayPayload.key, "barosense.pressureSamples.v1")
    }
}

/// When a snapshot is worth putting on the air.
///
/// The rule lives in `Shared/` rather than in `PressureCollectionController` precisely so
/// there is somewhere to assert it from — that type is in the iOS target, which no test
/// target builds.
final class PressureDisplayPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func snapshot(hPa: Double = 1013, at offset: TimeInterval = 0) -> PressureDisplaySnapshot {
        PressureDisplaySnapshot(
            sample: PressureSample(timestamp: now.addingTimeInterval(offset),
                                   pressure: Pressure(hectopascals: hPa)),
            trend: .steady
        )
    }

    func testTheFirstSnapshotOfASessionIsAlwaysPublished() {
        XCTAssertTrue(PressureDisplayPolicy.shouldPublish(snapshot(), lastPublished: nil))
    }

    func testANewReadingIsPublished() {
        let previous = snapshot(hPa: 1013)

        XCTAssertTrue(PressureDisplayPolicy.shouldPublish(snapshot(hPa: 1011, at: 900),
                                                          lastPublished: previous))
    }

    /// Two readings the same to the decimal are still two readings — the timestamp differs,
    /// so the watch's age caption would be wrong if this were skipped.
    func testAnUnchangedValueAtANewInstantIsStillPublished() {
        let previous = snapshot(hPa: 1013)

        XCTAssertTrue(PressureDisplayPolicy.shouldPublish(snapshot(hPa: 1013, at: 900),
                                                          lastPublished: previous))
    }

    /// The identical snapshot means the watch is already showing exactly this. Republishing
    /// it buys nothing and costs a delivery.
    func testRepublishingTheSameSnapshotIsSkipped() {
        let published = snapshot()

        XCTAssertFalse(PressureDisplayPolicy.shouldPublish(published, lastPublished: published))
    }

    /// The trend can move while the reading does not — a three-hour window slides, and its
    /// oldest sample eventually falls out of it. The watch's arrow has to follow.
    func testATrendChangeAloneIsPublished() {
        let previous = PressureDisplaySnapshot(
            sample: PressureSample(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                                   timestamp: now,
                                   pressure: Pressure(hectopascals: 1013)),
            trend: .steady
        )
        let sameReadingNewTrend = PressureDisplaySnapshot(sample: previous.sample, trend: .falling)

        XCTAssertTrue(PressureDisplayPolicy.shouldPublish(sameReadingNewTrend, lastPublished: previous))
    }
}
