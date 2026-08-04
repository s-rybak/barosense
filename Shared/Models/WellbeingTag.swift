import Foundation

/// A label the user attaches to a check-in — what made this one what it was, in their own
/// words.
///
/// Open-ended on purpose. The app ships a small starting set (`WellbeingTag.seeds`) and
/// the user adds, renames and retires tags from there, which is why this is a stored row
/// and not an `enum`: a set compiled into the binary cannot grow.
struct WellbeingTag: Identifiable, Hashable, Codable, Sendable {

    /// Stable for the life of the tag. Renaming changes `name` and never `id`, so a
    /// check-in recorded months ago still resolves to the same tag afterwards.
    let id: Identity

    /// What the user reads.
    ///
    /// For a `.seeded` tag this starts as the shipped default and becomes the user's own
    /// text the moment they rename it. For a `.user` tag it is their text from the start,
    /// and the same rule applies as to `CheckIn.note` — unbounded input, never a model
    /// feature, never part of an outbound payload.
    ///
    /// Localising the defaults later means resolving `ID.seeded` at display time, where a
    /// name still equal to the shipped default counts as "not renamed".
    let name: String

    /// Retired rather than removed. A hard delete would orphan every check-in pointing at
    /// this tag and silently rewrite history the model has already been fit on.
    let isArchived: Bool

    init(id: Identity, name: String, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.isArchived = isArchived
    }
}

extension WellbeingTag {

    /// Identity split by origin — which is also the line the copy rules care about: a
    /// `.seeded` name is text this app ships and an App Review reader sees, a `.user` name
    /// is not ours at all.
    ///
    /// Seeded tags carry a fixed slug instead of a generated identifier so that a watch
    /// and a phone seeding themselves independently produce the *same* row, rather than
    /// two rows that sync into a duplicate. The slugs are storage identity: existing
    /// check-ins point at them, so they must never be renamed.
    ///
    /// Spelled out rather than named `ID`: `Identifiable` infers the associated type from
    /// `id`, so call sites still read `WellbeingTag.ID`.
    enum Identity: Hashable, Codable, Sendable {
        case seeded(String)
        case user(UUID)
    }
}
