import Foundation

/// A check-in as the watch is able to record one, on its way to the phone's store.
///
/// A separate type from `CheckIn` and not a convenience: it is the **structural** form of
/// `CLAUDE.md` constraint 2. `CheckIn` also carries a free-text note and a list of
/// medications, both unbounded user text, and neither may cross a device boundary. Encoding
/// `CheckIn` directly would put that text one future watch field away from being on the air;
/// a type that has nowhere to put it cannot regress that way, and the compiler enforces it
/// rather than a comment asking nicely.
///
/// What does travel is the minimum a training row needs: when, how bad, and which of the
/// user's own labels applied.
struct WatchCheckIn: Identifiable, Hashable, Codable, Sendable {

    /// Generated on the watch and kept unchanged through the transfer.
    ///
    /// This is what makes redelivery harmless. `transferUserInfo` guarantees delivery but
    /// not exactly-once semantics across a reinstall or a restore, and `CheckInStore.save`
    /// replaces on matching `id` — so the same check-in arriving twice updates one row
    /// instead of doubling a training example.
    let id: UUID

    /// When the user reported it, taken on the watch at the moment they saved.
    ///
    /// Not when the phone received it, which can be hours later if the phone was off: a
    /// check-in filed at the wrong instant is aligned against the wrong weather, which is
    /// worse than no check-in at all.
    let timestamp: Date

    /// Higher is worse — see `CheckInIntensity`.
    let intensity: CheckInIntensity

    /// Identities only. The tag *names* travelled the other way, in `WatchContext`; sending
    /// them back would let a rename on the phone be overwritten by whatever text the watch
    /// happened to be showing.
    let tagIDs: Set<WellbeingTag.ID>

    init(id: UUID = UUID(),
         timestamp: Date,
         intensity: CheckInIntensity,
         tagIDs: Set<WellbeingTag.ID> = []) {
        self.id = id
        self.timestamp = timestamp
        self.intensity = intensity
        self.tagIDs = tagIDs
    }
}

extension WatchCheckIn {

    /// The row the phone stores. `note` and `medications` are left unset because the watch
    /// has no way to capture either — see the type's own documentation.
    var checkIn: CheckIn {
        CheckIn(id: id, timestamp: timestamp, intensity: intensity, tagIDs: tagIDs)
    }
}

/// Hands a check-in recorded on the watch to the phone, which owns the store.
///
/// ## Why this is not the display link
///
/// The two directions have opposite requirements and therefore cannot share a transport.
/// The display context is lossy on purpose — only the newest pressure matters. A check-in is
/// the opposite: it is user-entered data that exists nowhere else, and losing one loses a
/// training row the user cannot be asked to type again.
///
/// So this rides `transferUserInfo`: a FIFO queue the system persists and delivers when it
/// can, including after both apps have been terminated and relaunched. Three check-ins
/// entered on a hike with the phone at home arrive as three items when the phone is next in
/// range, in the order they were made. `sendMessage` would have needed the phone awake and
/// reachable at that moment and would simply have failed; `updateApplicationContext` keeps
/// one slot and would have delivered only the last of the three.
///
/// ## Why the watch does not just keep its own store
///
/// It would need a second SwiftData container, a second seeded tag vocabulary, and a merge
/// policy for two devices writing the same log — for a form the user fills in a few times a
/// day. The phone already owns the store; the queue is the cheap correct answer, and it is
/// the one the store's own `save` contract was written for.
protocol CheckInTransferLink: Sendable {

    /// Queues `checkIn` for delivery to the phone.
    ///
    /// Returns as soon as the item is queued; delivery happens whenever the system manages
    /// it. Throws only when the item could not be queued, which is the one case the caller
    /// can do something about — telling the user their check-in was not recorded so they can
    /// try again.
    ///
    /// **Deliberately not paired with a `canTransfer` flag to gate the save button.** The
    /// only thing that would make one false is a session still activating, which resolves in
    /// under a second and is not observable from a SwiftUI view — a form opened during that
    /// second would hold a permanently dead action, because nothing would invalidate the
    /// body when activation finished. Attempting and reporting has one state instead of two
    /// and cannot get stuck in the wrong one.
    ///
    /// Reachability is not a reason to refuse. The queue exists precisely to hold items while
    /// the phone is out of range or asleep.
    func transfer(_ checkIn: WatchCheckIn) throws
}

/// Used in previews and on a device with no counterpart.
///
/// Throws rather than silently swallowing: a double that accepted check-ins and dropped them
/// would let a preview — and eventually a real unpaired device — look like a form that works.
struct NoOpCheckInTransferLink: CheckInTransferLink {
    func transfer(_ checkIn: WatchCheckIn) throws { throw CheckInTransferError.linkUnavailable }
}

/// Wire format for a check-in travelling watch → phone.
enum CheckInTransferPayload {

    /// Versioned, and distinct from every key the other direction uses. The two directions
    /// share one `WCSession`, so a key collision would hand a check-in to the code that
    /// draws the pressure line.
    static let key = "barosense.checkIn.v1"

    static func encode(_ checkIn: WatchCheckIn) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return [key: try encoder.encode(checkIn)]
    }

    /// Returns `nil` when the payload is not ours — the session is shared, and an item
    /// belonging to some other feature is not an error here.
    static func decode(_ userInfo: [String: Any]) throws -> WatchCheckIn? {
        guard let data = userInfo[key] as? Data else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(WatchCheckIn.self, from: data)
        } catch {
            throw CheckInTransferError.malformedPayload
        }
    }
}

enum CheckInTransferError: Error, Sendable, Equatable {

    /// The session is not usable, so nothing can be queued. The form says so instead of
    /// accepting a check-in it would have to discard.
    case linkUnavailable

    /// Our key with bytes behind it that would not decode. Version skew or corruption.
    ///
    /// Unlike a dropped pressure context this is a **lost user report** — there is no next
    /// reading that supersedes it — so it is logged at error level on arrival rather than
    /// passed over quietly.
    case malformedPayload
}
