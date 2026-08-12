import Foundation

/// Storage for the user's tag vocabulary.
///
/// The vocabulary is per user and grows over the life of the install, so nothing may
/// assume it matches `WellbeingTag.seeds` — that list is only where a fresh install
/// starts. Implementations keep tag text on device: a user-authored name is free text and
/// falls under the same rule as `CheckIn.note`.
protocol WellbeingTagStore: Sendable {

    /// Tags on offer for a new check-in, ascending by `name`.
    ///
    /// Archived rows are excluded. They still exist — old check-ins reference them — but
    /// the user retired them and must not be offered them again.
    func activeTags() async throws -> [WellbeingTag]

    /// Every tag, archived included, ascending by `name`. This is what a history view
    /// needs to render a check-in tagged with something since retired.
    func allTags() async throws -> [WellbeingTag]

    /// Creates or replaces by `id`. A rename is a save carrying the same `id`, which is
    /// what keeps existing check-ins pointing at the tag.
    func save(_ tag: WellbeingTag) async throws

    /// Retires a tag, leaving the row in place. An unknown `id` is not an error.
    func archive(id: WellbeingTag.ID) async throws

    /// Removes every tag, archived rows included.
    ///
    /// The one hard delete on this protocol, and it exists for exactly one caller:
    /// "delete my data". Everywhere else a tag is archived rather than removed, because a
    /// hard delete orphans the check-ins pointing at it — but an erase is removing those
    /// check-ins too, so there is nothing left to orphan.
    func deleteAllTags() async throws

    /// Inserts every tag whose `id` is not already stored and leaves stored rows exactly
    /// as they are.
    ///
    /// Seeding runs whenever the store is opened, not once ever — a durable store cannot
    /// prove it is the first launch on a second device, and a "seeded" flag would be wrong
    /// as soon as one syncs. So this has to be idempotent, and it must not undo a rename
    /// or resurrect a tag the user archived.
    func insertIfAbsent(_ tags: [WellbeingTag]) async throws
}
