import Foundation

/// One entry of the tag vocabulary, trimmed to what a watch chip needs.
///
/// The phone owns the vocabulary — the user adds to it, renames it and retires from it —
/// so the watch cannot hold its own copy of `WellbeingTag.seeds` and stay right. It is sent
/// what is currently active and shows exactly that.
///
/// Not `WellbeingTag`, because `isArchived` is meaningless here: an archived tag is never
/// sent, and a flag that is always `false` on the wire is a field somebody will one day
/// read the wrong way round.
struct WatchTag: Identifiable, Hashable, Codable, Sendable {

    /// The same identity the phone stores against a check-in, carried unchanged. A tag
    /// chosen on the watch has to resolve to the row the phone already has, not to a new one.
    let id: WellbeingTag.ID

    /// What the user reads on the chip. Their own text once they have renamed anything, so
    /// it is displayed and never matched on.
    let name: String
}

extension WatchTag {

    /// How many chips the watch is offered.
    ///
    /// A 40 mm screen fits about six chips before the list stops being a glance and becomes
    /// a scroll, and the vocabulary is open-ended — a user who has added forty tags must not
    /// turn every context delivery into a forty-row payload. Twelve is two screenfuls: enough
    /// that the common ones are all there, bounded enough that the payload stays flat.
    ///
    /// The overflow is not lost, it is just not on the watch: the phone's own check-in form
    /// offers the whole vocabulary.
    static let maxOffered = 12

    /// The first `maxOffered` active tags, in the order both check-in forms list them.
    ///
    /// Seeded tags first, in the order they are declared, then everything the user added,
    /// alphabetically. That is the order the phone's own form uses, and matching it is the
    /// whole point: a user who reaches for the third chip on the phone must find the same
    /// tag in the same place on the watch.
    ///
    /// The ordering lives here rather than in either form because it now has three callers,
    /// and `Shared/` is the only one of the three places a test can reach. The two existing
    /// copies on the phone (`LogModel.inSeedOrder`, `OnboardingModel.inSeedOrder`) are left
    /// alone — folding them in means touching the onboarding flow, which is not this change.
    static func offered(from tags: [WellbeingTag]) -> [WatchTag] {
        let position = Dictionary(
            uniqueKeysWithValues: WellbeingTag.seeds.enumerated().map { ($1.id, $0) }
        )

        return tags
            .filter { !$0.isArchived }
            .sorted { lhs, rhs in
                switch (position[lhs.id], position[rhs.id]) {
                case let (left?, right?): left < right
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): lhs.name < rhs.name
                }
            }
            .prefix(maxOffered)
            .map { WatchTag(id: $0.id, name: $0.name) }
    }
}

/// Everything the phone tells the watch, in one value.
///
/// One struct rather than two independent publishes because there is only one slot to
/// publish into: `updateApplicationContext` replaces the whole dictionary on every call, so
/// a publisher that knew about only half of it would erase the other half. Composing the
/// whole context in one place is what makes that impossible rather than merely unlikely.
///
/// ## What is allowed to be in here
///
/// Environmental measurements, and the vocabulary of tag *names*. Nothing the user has
/// reported about themselves: no check-in values, no intensities, no Health values, no note
/// text. The vocabulary is the user's own words and stays theirs — it goes no further than
/// the two paired devices, is never part of a network request, and travels only because the
/// watch's check-in form is unusable without the labels it offers.
///
/// Widening this beyond that line is a gated decision under `CLAUDE.md` constraint 2, not an
/// edit to this struct.
struct WatchContext: Hashable, Codable, Sendable {

    /// The pressure half. `nil` before the phone's barometer has produced anything — a
    /// fresh install that has published its tag vocabulary but not yet taken a reading, and
    /// every iPad and simulator, which have no barometer at all.
    let pressure: PressureDisplaySnapshot?

    /// The chips the watch's check-in form offers. Empty until the phone has read its tag
    /// store, which happens once per launch.
    let tags: [WatchTag]

    init(pressure: PressureDisplaySnapshot? = nil, tags: [WatchTag] = []) {
        self.pressure = pressure
        self.tags = tags
    }

    /// Neither half has anything in it.
    ///
    /// The state the phone is in between launching and its first barometer reading, which is
    /// a real window of about a second — and the state it stays in for good on a device with
    /// no barometer or with Motion refused. Distinct from "nothing changed": this is a value
    /// that would *replace* what the watch is showing with nothing at all.
    var isEmpty: Bool { pressure == nil && tags.isEmpty }
}

/// Publishes the whole context to the paired watch.
///
/// Declared next to its consumer rather than beside `WCSession`, for the reason every other
/// service protocol in `Shared/` is: the phone's controller and its tests depend on this and
/// not on WatchConnectivity.
///
/// Fire-and-forget and deliberately **lossy**, matching the transport underneath it. The
/// watch needs the current state and has no use for the one before it, so a publish the
/// system supersedes before delivery has lost nothing. A check-in cannot be dropped that way,
/// which is why `CheckInTransferLink` is a separate protocol and not a direction flag here.
protocol WatchContextLink: Sendable {

    /// Offers `context` to the paired watch, replacing any undelivered one.
    func publish(_ context: WatchContext) async
}

/// Used on a device with no counterpart to talk to, and in previews.
struct NoOpWatchContextLink: WatchContextLink {
    func publish(_ context: WatchContext) async {}
}

/// When a context is worth putting on the air.
enum WatchContextPolicy {

    /// Whether `context` says anything the watch is not already showing.
    ///
    /// Two gates, and no third.
    ///
    /// **Empty is never published.** `updateApplicationContext` replaces the whole slot, and
    /// that slot is persisted on the watch across launches — it is what the watch draws from
    /// before the phone is even reachable. So publishing an empty context does not mean
    /// "nothing yet", it means *erase the reading the watch has been showing since yesterday*.
    /// The phone is empty for about a second on every launch, between the scene coming up and
    /// the barometer returning, and permanently on a device with no barometer or with Motion
    /// refused. Either would have taken the watch's number away.
    ///
    /// **Otherwise, did the content change.** There must not be a time-based gate on top of
    /// that: the single slot already collapses a burst into one delivery, so a rate limit
    /// could only make the watch staler than the phone.
    ///
    /// Pure, and here rather than in the phone's controller, because that type lives in
    /// `Barosense/` where no test target can reach it.
    static func shouldPublish(_ context: WatchContext, lastPublished: WatchContext?) -> Bool {
        guard !context.isEmpty else { return false }

        return context != lastPublished
    }
}

/// Wire format for the context.
///
/// **Two keys, not one.** The pressure half keeps the key and the exact bytes it has always
/// had, and the vocabulary rides in a second key beside it. That is what makes the two sides
/// independently updatable: a watch running the previous build finds the pressure key where
/// it expects it and ignores the one it has never heard of, so the number on its screen keeps
/// working through the release in which the phone learns to send tags. Folding both halves
/// into one new key would have made a staggered update look like a dead sensor.
enum WatchContextPayload {

    /// Where the tag vocabulary sits. Versioned for the same reason the pressure key is: the
    /// two devices update independently, and an unknown key must be ignored rather than
    /// mis-parsed.
    static let tagsKey = "barosense.watchTags.v1"

    static func encode(_ context: WatchContext) throws -> [String: Any] {
        var payload: [String: Any] = [:]

        if let pressure = context.pressure {
            payload.merge(try PressureDisplayPayload.encode(pressure)) { current, _ in current }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        payload[tagsKey] = try encoder.encode(context.tags)

        return payload
    }

    /// Returns `nil` when nothing in `context` is ours — a transfer belonging to some other
    /// feature is not an error here.
    ///
    /// Each half is independently optional. A context carrying only pressure decodes to a
    /// `WatchContext` with no tags rather than to nothing, because that is exactly what the
    /// previous build's phone sends and the watch must still show its number.
    static func decode(_ context: [String: Any]) throws -> WatchContext? {
        let pressure = try PressureDisplayPayload.decode(context)

        let tags: [WatchTag]?
        if let data = context[tagsKey] as? Data {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                tags = try decoder.decode([WatchTag].self, from: data)
            } catch {
                throw WatchContextError.malformedPayload
            }
        } else {
            tags = nil
        }

        guard pressure != nil || tags != nil else { return nil }

        return WatchContext(pressure: pressure, tags: tags ?? [])
    }
}

enum WatchContextError: Error, Sendable, Equatable {

    /// A key was present but the bytes behind it did not decode. A version skew the version
    /// tag failed to catch, or a corrupt transfer. Dropped, never guessed at.
    case malformedPayload
}
