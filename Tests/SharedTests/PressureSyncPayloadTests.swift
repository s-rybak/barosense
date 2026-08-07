import XCTest
@testable import Barosense

/// The wire format between the watch and the phone. A codec bug here is invisible on both
/// devices and shows up only as a training log that quietly disagrees with the watch.
final class PressureSyncPayloadTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    func testRoundTripPreservesIdentifierTimestampAndValue() throws {
        let samples = [
            PressureSample(timestamp: now, pressure: Pressure(hectopascals: 1013.2)),
            PressureSample(timestamp: now.addingTimeInterval(3600), pressure: Pressure(hectopascals: 1011.8))
        ]

        let decoded = try PressureSyncPayload.decode(try PressureSyncPayload.encode(samples))

        XCTAssertEqual(decoded.map(\.id), samples.map(\.id))
        XCTAssertEqual(decoded.map(\.pressure.hectopascals), [1013.2, 1011.8])
        XCTAssertEqual(decoded.map(\.timestamp), samples.map(\.timestamp))
    }

    /// The identifier is what makes resending a whole window cheap: the receiver upserts on
    /// it. If it were regenerated in transit, every hand-off would multiply the history.
    func testIdentifiersSurviveTheTransferSoRedeliveryStaysIdempotent() throws {
        let sample = PressureSample(timestamp: now, pressure: Pressure(hectopascals: 1013))

        let first = try PressureSyncPayload.decode(try PressureSyncPayload.encode([sample]))
        let second = try PressureSyncPayload.decode(try PressureSyncPayload.encode([sample]))

        XCTAssertEqual(first.first?.id, second.first?.id)
    }

    func testEmptyBatchRoundTripsToNothing() throws {
        let decoded = try PressureSyncPayload.decode(try PressureSyncPayload.encode([]))
        XCTAssertTrue(decoded.isEmpty)
    }

    /// A transfer belonging to some other feature is not an error — the session is shared.
    func testAPayloadWithoutOurKeyDecodesToNothing() throws {
        XCTAssertTrue(try PressureSyncPayload.decode(["somethingElse": Data()]).isEmpty)
        XCTAssertTrue(try PressureSyncPayload.decode([:]).isEmpty)
    }

    /// Version skew or a corrupt transfer. Dropped, never guessed at — a half-parsed reading
    /// would become a training row nobody could trace.
    func testCorruptBytesUnderOurKeyThrowRatherThanDecodePartially() {
        let payload: [String: Any] = [PressureSyncPayload.key: Data("not json".utf8)]

        XCTAssertThrowsError(try PressureSyncPayload.decode(payload)) { error in
            XCTAssertEqual(error as? PressureSyncError, .malformedPayload)
        }
    }

    func testWrongTypeUnderOurKeyIsIgnoredRatherThanCrashing() throws {
        XCTAssertTrue(try PressureSyncPayload.decode([PressureSyncPayload.key: "a string"]).isEmpty)
    }
}
