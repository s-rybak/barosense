import XCTest
@testable import Barosense

/// The watch → phone direction: a check-in the user made on their wrist, on its way to the
/// only store that keeps one.
///
/// The stakes here are different from the display context's. A dropped context is superseded
/// by the next reading; a dropped check-in is a report the user cannot be asked to make again.
final class CheckInTransferPayloadTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func checkIn(intensity: Int = 6,
                         tags: Set<WellbeingTag.ID> = [.seeded("headache")]) -> WatchCheckIn {
        WatchCheckIn(id: UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF")!,
                     timestamp: now,
                     intensity: CheckInIntensity(clamping: intensity),
                     tagIDs: tags)
    }

    func testACheckInSurvivesTheRoundTripUnchanged() throws {
        let original = checkIn()

        let decoded = try CheckInTransferPayload.decode(CheckInTransferPayload.encode(original))

        XCTAssertEqual(decoded, original)
    }

    /// The identifier is what makes redelivery harmless: `CheckInStore.save` replaces on a
    /// matching `id`, so the same report landing twice updates one row instead of doubling a
    /// training example. A regenerated identifier would silently turn that into two.
    func testTheIdentifierIsCarriedRatherThanRegenerated() throws {
        let original = checkIn()

        let decoded = try CheckInTransferPayload.decode(CheckInTransferPayload.encode(original))

        XCTAssertEqual(decoded?.id, original.id)
    }

    /// The instant is the one the user reported at, and it can be hours before the phone
    /// receives it. A timestamp that shifted in transit would align the check-in against the
    /// wrong weather, which is worse than not having it.
    func testTheReportedInstantIsNotRewrittenInTransit() throws {
        let decoded = try CheckInTransferPayload.decode(CheckInTransferPayload.encode(checkIn()))

        XCTAssertEqual(decoded?.timestamp, now)
    }

    /// Higher is worse, and the whole 1–10 range has to survive: an intensity that came back
    /// off by one would move check-ins across the label threshold.
    func testEveryPointOfTheScaleCrossesIntact() throws {
        for value in CheckInIntensity.scale {
            let decoded = try CheckInTransferPayload.decode(
                CheckInTransferPayload.encode(checkIn(intensity: value))
            )
            XCTAssertEqual(decoded?.intensity.rawValue, value)
        }
    }

    func testBothTagOriginsCrossIntact() throws {
        let userTag = UUID(uuidString: "00000000-0000-0000-0000-0000000000A7")!
        let tags: Set<WellbeingTag.ID> = [.seeded("fatigue"), .user(userTag)]

        let decoded = try CheckInTransferPayload.decode(
            CheckInTransferPayload.encode(checkIn(tags: tags))
        )

        XCTAssertEqual(decoded?.tagIDs, tags)
    }

    func testACheckInWithNoTagsIsStillACheckIn() throws {
        let decoded = try CheckInTransferPayload.decode(
            CheckInTransferPayload.encode(checkIn(tags: []))
        )

        XCTAssertEqual(decoded?.tagIDs, [])
    }

    /// The session is shared with the display link. A key collision would hand a check-in to
    /// the code that draws the pressure line.
    func testTheKeyDoesNotCollideWithEitherDisplayKey() {
        XCTAssertNotEqual(CheckInTransferPayload.key, PressureDisplayPayload.key)
        XCTAssertNotEqual(CheckInTransferPayload.key, WatchContextPayload.tagsKey)
    }

    func testAnItemWithoutOurKeyIsNotOurs() throws {
        XCTAssertNil(try CheckInTransferPayload.decode(["somethingElse": Data()]))
        XCTAssertNil(try CheckInTransferPayload.decode([:]))
    }

    func testOurKeyWithUndecodableBytesThrows() {
        let userInfo: [String: Any] = [CheckInTransferPayload.key: Data("not json".utf8)]

        XCTAssertThrowsError(try CheckInTransferPayload.decode(userInfo)) { error in
            XCTAssertEqual(error as? CheckInTransferError, .malformedPayload)
        }
    }
}

/// What the watch is structurally unable to send, and what the phone stores when it arrives.
final class WatchCheckInMappingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    /// `CLAUDE.md` constraint 2, asserted rather than trusted to a comment. The note and the
    /// medication list are unbounded user text and must not cross a device boundary; the
    /// transfer type has nowhere to put them, and this is the test that fails if somebody
    /// gives it one.
    func testNoUnboundedUserTextCanCrossTheBoundary() {
        let transferred = WatchCheckIn(timestamp: now,
                                       intensity: CheckInIntensity(clamping: 7)).checkIn

        XCTAssertNil(transferred.note)
        XCTAssertEqual(transferred.medications, [])
    }

    /// The row the phone writes is the report the watch made, field for field.
    func testTheStoredRowIsTheTransferredReport() {
        let id = UUID()
        let transfer = WatchCheckIn(id: id,
                                    timestamp: now,
                                    intensity: CheckInIntensity(clamping: 9),
                                    tagIDs: [.seeded("migraine")]) // barosense:copy-allow frozen storage slug

        let stored = transfer.checkIn

        XCTAssertEqual(stored.id, id)
        XCTAssertEqual(stored.timestamp, now)
        XCTAssertEqual(stored.intensity.rawValue, 9)
        XCTAssertEqual(stored.tagIDs, [.seeded("migraine")]) // barosense:copy-allow frozen slug
    }
}

/// The double stands in wherever there is no session, and it has one job beyond compiling:
/// it must not look like a working link.
final class NoOpCheckInTransferLinkTests: XCTestCase {

    /// It throws rather than silently swallowing. A double that accepted check-ins and
    /// dropped them would let a preview, and eventually a device with no pairing, look like a
    /// form that works.
    func testTheDoubleRefusesRatherThanSwallowing() {
        let checkIn = WatchCheckIn(timestamp: .now, intensity: CheckInIntensity(clamping: 5))

        XCTAssertThrowsError(try NoOpCheckInTransferLink().transfer(checkIn)) { error in
            XCTAssertEqual(error as? CheckInTransferError, .linkUnavailable)
        }
    }
}
