import XCTest
@testable import Barosense

final class WellbeingTagTests: XCTestCase {

    // MARK: - Storage format

    func testSeedSlugsAreFrozen() {
        // The one place the slugs are written out. They are what stored check-ins point
        // at, so a rename here orphans history — it has to fail a test, not a review.
        let slugs = WellbeingTag.seeds.map(\.id)

        XCTAssertEqual(slugs, [.seeded("headache"), // barosense:copy-allow frozen slug
                               .seeded("migraine"), // barosense:copy-allow frozen slug
                               .seeded("fatigue"),
                               .seeded("joints"),
                               .seeded("sleep"),
                               .seeded("mood"),
                               .seeded("dizziness")])
    }

    func testSeedIdentifiersAreUnique() {
        XCTAssertEqual(Set(WellbeingTag.seeds.map(\.id)).count, WellbeingTag.seeds.count)
    }

    func testLegacySeedIdentityUsesApprovedDisplayName() throws {
        let legacyID = WellbeingTag.ID.seeded("migraine") // barosense:copy-allow frozen storage slug
        let tag = try XCTUnwrap(WellbeingTag.seeds.first { $0.id == legacyID })

        XCTAssertEqual(tag.name, "Severe headache")
    }

    func testSeedsShipActive() {
        // A seed arriving archived would be invisible with no way for the user to find it.
        XCTAssertTrue(WellbeingTag.seeds.allSatisfy { !$0.isArchived })
    }

    func testBothIdentityKindsSurviveACodableRoundTrip() throws {
        let tags = [WellbeingTag(id: .seeded("fatigue"), name: "Fatigue"),
                    WellbeingTag(id: .user(UUID()), name: "Long drive", isArchived: true)]

        let decoded = try JSONDecoder().decode([WellbeingTag].self,
                                               from: JSONEncoder().encode(tags))

        XCTAssertEqual(decoded, tags)
    }

    // MARK: - Identity

    func testSeededAndUserIdentitiesNeverCollide() {
        let seeded = WellbeingTag(id: .seeded("fatigue"), name: "Fatigue")
        let renamed = WellbeingTag(id: .seeded("fatigue"), name: "Worn out")
        let user = WellbeingTag(id: .user(UUID()), name: "Fatigue")

        // Identity is the id, never the text: a rename is the same tag, and a user tag
        // that happens to be typed with a seed's wording is a different one.
        XCTAssertEqual(seeded.id, renamed.id)
        XCTAssertNotEqual(seeded.id, user.id)
    }
}
