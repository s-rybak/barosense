import XCTest
@testable import Barosense

/// Exercised through `any WellbeingTagStore`: the durable store has to pass this same
/// file, and the seeding contract is the part most likely to be got wrong there.
final class InMemoryWellbeingTagStoreTests: XCTestCase {

    private func tag(_ slug: String,
                     name: String,
                     isArchived: Bool = false) -> WellbeingTag {
        WellbeingTag(id: .seeded(slug), name: name, isArchived: isArchived)
    }

    // MARK: - Seeding

    func testSeedingAnEmptyStoreInsertsEverySeed() async throws {
        let store: any WellbeingTagStore = InMemoryWellbeingTagStore()

        try await store.insertIfAbsent(WellbeingTag.seeds)

        let stored = try await store.allTags()
        XCTAssertEqual(Set(stored.map(\.id)), Set(WellbeingTag.seeds.map(\.id)))
    }

    func testSeedingTwiceDoesNotDuplicate() async throws {
        // Seeding runs at every open, not once ever.
        let store: any WellbeingTagStore = InMemoryWellbeingTagStore()

        try await store.insertIfAbsent(WellbeingTag.seeds)
        try await store.insertIfAbsent(WellbeingTag.seeds)

        let stored = try await store.allTags()
        XCTAssertEqual(stored.count, WellbeingTag.seeds.count)
    }

    func testSeedingDoesNotUndoARename() async throws {
        let store: any WellbeingTagStore = InMemoryWellbeingTagStore()
        try await store.insertIfAbsent([tag("fatigue", name: "Fatigue")])

        try await store.save(tag("fatigue", name: "Worn out"))
        try await store.insertIfAbsent([tag("fatigue", name: "Fatigue")])

        let stored = try await store.allTags()
        XCTAssertEqual(stored.map(\.name), ["Worn out"])
    }

    func testSeedingDoesNotResurrectAnArchivedTag() async throws {
        // The reason `insertIfAbsent` keys on id and not on presence-among-active: a user
        // who retires a shipped tag must not get it back at the next launch.
        let store: any WellbeingTagStore = InMemoryWellbeingTagStore()
        try await store.insertIfAbsent([tag("joints", name: "Joints")])
        try await store.archive(id: .seeded("joints"))

        try await store.insertIfAbsent([tag("joints", name: "Joints")])

        let active = try await store.activeTags()
        XCTAssertTrue(active.isEmpty)
    }

    // MARK: - Reads

    func testActiveTagsExcludeArchivedButAllTagsKeepThem() async throws {
        // A check-in tagged before the tag was retired still has to render.
        let store: any WellbeingTagStore = InMemoryWellbeingTagStore(
            [tag("fatigue", name: "Fatigue"),
             tag("joints", name: "Joints", isArchived: true)])

        let active = try await store.activeTags()
        let all = try await store.allTags()

        XCTAssertEqual(active.map(\.name), ["Fatigue"])
        XCTAssertEqual(all.map(\.name), ["Fatigue", "Joints"])
    }

    func testTagsComeBackAscendingByName() async throws {
        let store: any WellbeingTagStore = InMemoryWellbeingTagStore(
            [tag("joints", name: "Joints"), tag("fatigue", name: "Fatigue")])

        let active = try await store.activeTags()

        XCTAssertEqual(active.map(\.name), ["Fatigue", "Joints"])
    }

    // MARK: - Writes

    func testUserCreatedTagsLiveAlongsideSeeds() async throws {
        let store: any WellbeingTagStore = InMemoryWellbeingTagStore()
        try await store.insertIfAbsent(WellbeingTag.seeds)

        try await store.save(WellbeingTag(id: .user(UUID()), name: "Long drive"))

        let active = try await store.activeTags()
        XCTAssertEqual(active.count, WellbeingTag.seeds.count + 1)
    }

    func testArchivingAnUnknownTagIsNotAnError() async throws {
        let store: any WellbeingTagStore = InMemoryWellbeingTagStore()

        try await store.archive(id: .user(UUID()))
    }
}
