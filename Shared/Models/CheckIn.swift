import Foundation

/// How the user rates their wellbeing in a single check-in, on the 1–5 scale the model is
/// trained against. 1 is the worst end.
///
/// An enum rather than an `Int` because a score of 0 or 7 must not be representable: the
/// label threshold and every reported metric assume the closed 1–5 range, and a value
/// outside it would be silently absorbed instead of rejected.
///
/// Raw values are persisted. They are part of the storage format and must not be
/// renumbered.
enum WellbeingScore: Int, CaseIterable, Codable, Sendable {
    case veryPoor = 1
    case poor = 2
    case fair = 3
    case good = 4
    case veryGood = 5
}

extension WellbeingScore: Comparable {
    static func < (lhs: WellbeingScore, rhs: WellbeingScore) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Optional self-reported tags attached to a check-in.
///
/// Recorded from v1 but deliberately outside the v1 label — see `WellbeingLabel`. They
/// exist so "does the pressure signal differ by tag" becomes answerable once there is
/// enough history, not because anything reads them today.
///
/// Raw values are persisted and must not be renamed.
enum WellbeingTag: String, CaseIterable, Codable, Sendable {
    case headache
    case fatigue
    case joints
}

/// One self-reported wellbeing check-in — the unit of user input, and the row the model
/// is trained on.
///
/// A value type on purpose. This is what the feature pipeline consumes, so it has to be
/// constructible in a plain unit test with no store, no container and no device.
/// Persistence maps to and from it (`CheckInStore`) and never hands a storage type back.
struct CheckIn: Identifiable, Hashable, Codable, Sendable {

    /// Stable identity across edits and across the watch→phone transfer, so a check-in
    /// entered on the watch and delivered twice does not become two training rows.
    let id: UUID

    /// When the user reported this, not when it reached storage. Features are computed at
    /// this instant, so the two must not be conflated.
    let timestamp: Date

    let score: WellbeingScore

    let tags: Set<WellbeingTag>

    /// Free-text reflection. Never becomes a feature and never joins an outbound payload:
    /// it is unbounded user text and the only part of a check-in that can contain
    /// anything at all.
    let note: String?

    init(id: UUID = UUID(),
         timestamp: Date,
         score: WellbeingScore,
         tags: Set<WellbeingTag> = [],
         note: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.score = score
        self.tags = tags
        self.note = note
    }
}
