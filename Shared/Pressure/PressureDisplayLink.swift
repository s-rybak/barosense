import Foundation

/// What the watch shows: the phone's latest reading and how pressure has been moving.
///
/// Deliberately not a window of history. The watch is a companion display — one number read
/// in about half a second (`.claude/skills/watchos_budget/SKILL.md`) — and the chart lives on
/// the phone, where there is room for it. Sending a series the watch cannot usefully draw
/// would be radio work bought for nothing.
///
/// Environmental measurements only. No check-in values, no Health values, no note text: this
/// crosses a device boundary, and widening it is a gated decision under `CLAUDE.md`
/// constraint 2 rather than an edit to this struct.
struct PressureDisplaySnapshot: Hashable, Codable, Sendable {

    /// The last reading the phone's barometer actually took. Never a forecast value — the
    /// watch's number is ground truth for "now" or it is nothing.
    let sample: PressureSample

    /// The trailing three-hour tendency, computed on the phone from the full log. Computed
    /// there and shipped rather than derived here, because the watch holds no history to
    /// derive it from.
    let trend: PressureTrend
}

/// Hands the phone's latest reading to the watch for display.
///
/// Declared next to its consumer for the same reason `PressureSource` is: the phone's
/// controller and its tests depend on this and not on `WCSession`.
///
/// Deliberately fire-and-forget, and deliberately *lossy*. The watch needs the newest value
/// and has no use for the one before it, so a publish the system supersedes before delivery
/// has lost nothing. That is the opposite of the training log's requirement, and it is why
/// this is a separate protocol rather than a direction flag on one shared type.
protocol PressureDisplayLink: Sendable {

    /// Offers `snapshot` to the paired watch, replacing any undelivered one.
    func publish(_ snapshot: PressureDisplaySnapshot) async
}

/// Used on a device with no counterpart to talk to, and in previews.
struct NoOpPressureDisplayLink: PressureDisplayLink {
    func publish(_ snapshot: PressureDisplaySnapshot) async {}
}

/// When a snapshot is worth putting on the air.
enum PressureDisplayPolicy {

    /// Whether `snapshot` says anything the watch is not already showing.
    ///
    /// Pure, and here rather than in the phone's controller, because that type lives in
    /// `Barosense/` where no test target can reach it.
    ///
    /// The only gate is *did the content change*. There is no time-based throttle and there
    /// must not be one: `updateApplicationContext` already keeps a single slot that the next
    /// call overwrites, so a burst costs one delivery, and a rate limit on top of that would
    /// only be able to make the watch's number staler than the phone's.
    static func shouldPublish(_ snapshot: PressureDisplaySnapshot,
                              lastPublished: PressureDisplaySnapshot?) -> Bool {
        snapshot != lastPublished
    }
}

/// Wire format for the display snapshot.
///
/// A `Codable` round trip through JSON rather than a hand-rolled dictionary of primitives:
/// `PressureDisplaySnapshot` already is `Codable`, and hand-mapping fields is exactly where a
/// hectopascal quietly becomes a kilopascal.
enum PressureDisplayPayload {

    /// Versioned because the receiver may be an older build than the sender — the watch and
    /// the phone update independently. An unknown key is ignored rather than mis-parsed.
    ///
    /// `v2` and not `v1`: `v1` carried a batch of samples travelling the other way, from the
    /// watch's barometer to the phone's log. A watch still running that build would read a
    /// `v1` key as history to ingest, so the new payload must not reuse the name.
    static let key = "barosense.pressureDisplay.v2"

    static func encode(_ snapshot: PressureDisplaySnapshot) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return [key: try encoder.encode(snapshot)]
    }

    /// Returns `nil` when the payload is not ours — a transfer for some other feature is not
    /// an error here.
    static func decode(_ context: [String: Any]) throws -> PressureDisplaySnapshot? {
        guard let data = context[key] as? Data else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PressureDisplaySnapshot.self, from: data)
        } catch {
            throw PressureDisplayError.malformedPayload
        }
    }
}

enum PressureDisplayError: Error, Sendable, Equatable {

    /// The key was present but the bytes behind it did not decode. A version skew the
    /// version tag failed to catch, or a corrupt transfer. Dropped, never guessed at.
    case malformedPayload
}
