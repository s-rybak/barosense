import Foundation

/// Hands readings taken on one device to the device that keeps the training log.
///
/// Declared next to its consumer for the same reason `PressureSource` is: the watch
/// controller and its tests depend on this and not on `WCSession`.
///
/// Deliberately fire-and-forget. Delivery is queued by the system and can take hours — the
/// phone may be off, out of range, or not running — and a caller that could `await` the
/// outcome would end up designing around a promise nothing can keep. The sender's own
/// durable log is the copy that matters; the uplink is how it propagates.
protocol PressureSampleUplink: Sendable {

    /// Queues `samples` for the paired device. Empty input is a no-op.
    ///
    /// Safe to call with rows that have already been sent: every sample carries the
    /// identifier the sending device generated, and the receiver upserts on it. That is
    /// what makes resending a whole window the cheap way to heal a dropped transfer.
    func send(_ samples: [PressureSample]) async
}

/// Used on a device with no counterpart to talk to, and in previews.
struct NoOpPressureSampleUplink: PressureSampleUplink {
    func send(_ samples: [PressureSample]) async {}
}

/// How much history the sender re-ships on every hand-off.
///
/// Six hours, which at the target ≥1 sample/h is roughly six rows and a few hundred bytes
/// per transfer. The alternative — sending only the newest reading — makes every dropped
/// transfer a permanent hole in the training history, because nothing ever revisits it. An
/// overlapping window costs bytes nobody notices and heals itself on the next wake.
enum PressureUplinkPolicy {
    static let resendWindowSeconds: TimeInterval = 6 * 3600
}

/// Wire format for a batch of readings crossing between the watch and the phone.
///
/// A `Codable` round trip through JSON rather than a hand-rolled dictionary of primitives:
/// `PressureSample` already is `Codable`, and hand-mapping fields is exactly where a
/// hectopascal quietly becomes a kilopascal.
///
/// This payload carries barometric readings and nothing else — no check-ins, no Health
/// values, no note text. Pressure is an environmental measurement, and this transfer stays
/// between the user's own paired devices, but the boundary is worth stating: widening the
/// payload is a gated decision under `CLAUDE.md` constraint 2, not an edit to this file.
enum PressureSyncPayload {

    /// Versioned because the receiver may be an older build than the sender — the watch and
    /// the phone update independently. An unknown key is ignored rather than mis-parsed.
    static let key = "barosense.pressureSamples.v1"

    static func encode(_ samples: [PressureSample]) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return [key: try encoder.encode(samples)]
    }

    /// Returns an empty array when the payload is not ours — a transfer for some other
    /// feature is not an error here.
    static func decode(_ userInfo: [String: Any]) throws -> [PressureSample] {
        guard let data = userInfo[key] as? Data else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([PressureSample].self, from: data)
        } catch {
            throw PressureSyncError.malformedPayload
        }
    }
}

enum PressureSyncError: Error, Sendable, Equatable {

    /// The key was present but the bytes behind it did not decode. A version skew the
    /// version tag failed to catch, or a corrupt transfer. Dropped, never guessed at.
    case malformedPayload
}
