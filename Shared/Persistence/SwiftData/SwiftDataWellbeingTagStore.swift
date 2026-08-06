import Foundation
import SwiftData

/// Durable row for `WellbeingTag`.
///
/// The identity is held as a single string key rather than as the enum, because SwiftData
/// cannot index or write a `#Predicate` against an enum with associated values. The key
/// format is storage identity — existing rows are matched by it, so it is frozen.
@Model
final class StoredWellbeingTag {

    /// `WellbeingTag.Identity` flattened — see `identityKey(for:)`. Unique in practice:
    /// every write path fetches by this key first.
    var identityKey: String = ""

    var name: String = ""

    var isArchived: Bool = false

    init(tag: WellbeingTag) {
        self.identityKey = StoredWellbeingTag.identityKey(for: tag.id)
        self.name = tag.name
        self.isArchived = tag.isArchived
    }

    /// `nil` when the stored key does not parse — a row written by a build that knew a
    /// third identity kind. Skipped on read instead of crashing the vocabulary.
    var tag: WellbeingTag? {
        guard let id = StoredWellbeingTag.identity(from: identityKey) else { return nil }
        return WellbeingTag(id: id, name: name, isArchived: isArchived)
    }

    // MARK: - Identity encoding

    /// `seeded:headache`, `user:<uuid>`. // barosense:copy-allow storage key example
    ///
    /// The two kinds carry their own prefix so a seeded slug and a user identifier can
    /// never collide, which is the guarantee `WellbeingTag.Identity` makes in the domain.
    static func identityKey(for id: WellbeingTag.ID) -> String {
        switch id {
        case .seeded(let slug): "seeded:\(slug)"
        case .user(let uuid): "user:\(uuid.uuidString)"
        }
    }

    /// Inverse of `identityKey(for:)`. Splits on the *first* separator only, so a slug
    /// containing one would still round-trip.
    static func identity(from key: String) -> WellbeingTag.ID? {
        guard let separator = key.firstIndex(of: ":") else { return nil }
        let kind = key[..<separator]
        let value = String(key[key.index(after: separator)...])

        switch kind {
        case "seeded":
            return value.isEmpty ? nil : .seeded(value)
        case "user":
            return UUID(uuidString: value).map(WellbeingTag.ID.user)
        default:
            return nil
        }
    }
}

/// On-disk `WellbeingTagStore`.
///
/// A `@ModelActor` for the same reason as `SwiftDataUserProfileStore`: the context stays
/// inside, only `WellbeingTag` values come out.
@ModelActor
actor SwiftDataWellbeingTagStore: WellbeingTagStore {

    func activeTags() throws -> [WellbeingTag] {
        try byName(storedTags().filter { !$0.isArchived })
    }

    func allTags() throws -> [WellbeingTag] {
        try byName(storedTags())
    }

    func save(_ tag: WellbeingTag) throws {
        let key = StoredWellbeingTag.identityKey(for: tag.id)

        if let existing = try storedTag(key: key) {
            existing.name = tag.name
            existing.isArchived = tag.isArchived
        } else {
            modelContext.insert(StoredWellbeingTag(tag: tag))
        }
        try modelContext.save()
    }

    func archive(id: WellbeingTag.ID) throws {
        let key = StoredWellbeingTag.identityKey(for: id)
        guard let existing = try storedTag(key: key), !existing.isArchived else { return }

        existing.isArchived = true
        try modelContext.save()
    }

    func insertIfAbsent(_ tags: [WellbeingTag]) throws {
        // Fetch the whole key set once instead of a query per tag: seeding runs on every
        // launch, and the vocabulary is small enough that one round trip is cheaper than
        // `tags.count` of them.
        let existingKeys = Set(try storedTags().map(\.identityKey))

        var inserted = false
        for tag in tags {
            let key = StoredWellbeingTag.identityKey(for: tag.id)
            guard !existingKeys.contains(key) else { continue }

            modelContext.insert(StoredWellbeingTag(tag: tag))
            inserted = true
        }

        // No insert, no write. Seeding is idempotent and runs at every launch; an
        // unconditional `save()` would cost an fsync each time for nothing.
        guard inserted else { return }
        try modelContext.save()
    }

    // MARK: - Fetching

    /// Every stored row, unfiltered.
    ///
    /// No `#Predicate` anywhere in this store: the macro expansion captures a `KeyPath`
    /// into a non-`Sendable` `@Model` type, which warns under complete strict concurrency
    /// today and is an error under the Swift 6 language mode. Filtering in Swift is the
    /// same trade `InMemoryWellbeingTagStore` makes, and it holds for the same reason —
    /// a personal tag vocabulary is tens of rows, not thousands. Revisit if that stops
    /// being true.
    private func storedTags() throws -> [StoredWellbeingTag] {
        try modelContext.fetch(FetchDescriptor<StoredWellbeingTag>())
    }

    private func storedTag(key: String) throws -> StoredWellbeingTag? {
        try storedTags().first { $0.identityKey == key }
    }

    /// Plain string ordering, matching `InMemoryWellbeingTagStore`: the two
    /// implementations have to be interchangeable, and collation for display is the UI's
    /// problem. Rows whose identity no longer parses are dropped here.
    private func byName(_ stored: [StoredWellbeingTag]) -> [WellbeingTag] {
        stored
            .compactMap(\.tag)
            .sorted { $0.name < $1.name }
    }
}
