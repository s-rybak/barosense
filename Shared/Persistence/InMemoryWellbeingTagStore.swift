import Foundation

/// Non-persistent `WellbeingTagStore` for unit tests, SwiftUI previews, and bring-up
/// before a durable store exists. Contents are lost with the process.
actor InMemoryWellbeingTagStore: WellbeingTagStore {

    private var storage: [WellbeingTag.ID: WellbeingTag] = [:]

    init(_ tags: [WellbeingTag] = []) {
        for tag in tags {
            storage[tag.id] = tag
        }
    }

    func activeTags() -> [WellbeingTag] {
        byName(storage.values.filter { !$0.isArchived })
    }

    func allTags() -> [WellbeingTag] {
        byName(storage.values)
    }

    func save(_ tag: WellbeingTag) {
        storage[tag.id] = tag
    }

    func archive(id: WellbeingTag.ID) {
        guard let tag = storage[id] else { return }
        storage[id] = WellbeingTag(id: tag.id, name: tag.name, isArchived: true)
    }

    func insertIfAbsent(_ tags: [WellbeingTag]) {
        for tag in tags where storage[tag.id] == nil {
            storage[tag.id] = tag
        }
    }

    /// Plain string ordering, not `localizedStandardCompare`: it has to be reproducible in
    /// a test on any locale. Collation for display is the UI's problem.
    private func byName(_ tags: some Sequence<WellbeingTag>) -> [WellbeingTag] {
        tags.sorted { $0.name < $1.name }
    }
}
