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

    // MARK: - Matching a typed name

    // What stops the add-tag fields on the check-in sheet and in Edit Profile from filing a
    // second tag that means what an existing one already means.

    func testASeedIsNamedByItsShippedName() {
        let fatigue = WellbeingTag(id: .seeded("fatigue"), name: "Fatigue")

        XCTAssertTrue(fatigue.isNamed("Fatigue"))
    }

    func testMatchingIgnoresCase() {
        let fatigue = WellbeingTag(id: .seeded("fatigue"), name: "Fatigue")

        XCTAssertTrue(fatigue.isNamed("fatigue"))
        XCTAssertTrue(WellbeingTag(id: .user(UUID()), name: "Long drive").isNamed("LONG DRIVE"))
    }

    func testASeedIsNamedByItsTranslationInEveryShippedLanguage() {
        // The point of the whole mechanism. Settings can switch the app to Ukrainian, where
        // this tag draws as "Втома" while it is still stored as "Fatigue" — so the word the
        // user reads has to match the row, or they get a duplicate of it.
        let fatigue = WellbeingTag(id: .seeded("fatigue"), name: "Fatigue")

        XCTAssertTrue(fatigue.isNamed("Втома"))
        XCTAssertTrue(fatigue.isNamed("втома"))
    }

    func testMatchingHoldsInBothDirectionsAcrossALanguageSwitch() {
        // Someone who built their vocabulary in Ukrainian and then switched to English is the
        // same case running the other way.
        let dizziness = WellbeingTag(id: .seeded("dizziness"), name: "Dizziness")

        XCTAssertTrue(dizziness.isNamed("Dizziness"))
        XCTAssertTrue(dizziness.isNamed("Запаморочення"))
    }

    func testARenamedSeedIsNamedOnlyByWhatTheUserCalledIt() {
        // Once renamed, the text is the user's, not app copy. Still answering to the shipped
        // translation would mean typing "Втома" resurrects a word they deliberately replaced.
        let renamed = WellbeingTag(id: .seeded("fatigue"), name: "Worn out")

        XCTAssertTrue(renamed.isNamed("Worn out"))
        XCTAssertFalse(renamed.isNamed("Fatigue"))
        XCTAssertFalse(renamed.isNamed("Втома"))
    }

    func testAUserTagIsNeverPutThroughALookup() {
        // A user tag whose text happens to be one of ours stays their text in both languages.
        let user = WellbeingTag(id: .user(UUID()), name: "Fatigue")

        XCTAssertTrue(user.isNamed("Fatigue"))
        XCTAssertFalse(user.isNamed("Втома"))
    }

    func testUnrelatedWordsDoNotMatch() {
        let fatigue = WellbeingTag(id: .seeded("fatigue"), name: "Fatigue")

        XCTAssertFalse(fatigue.isNamed("Headache")) // barosense:copy-allow default wellbeing tag
        XCTAssertFalse(fatigue.isNamed(""))
    }

    // MARK: - Bounding a typed name

    // Both add-tag fields go through `storedName`, so this is what either of them stores.

    func testAnOrdinaryNameIsStoredAsTyped() {
        XCTAssertEqual(WellbeingTag.storedName(from: "Тиск у скронях"), "Тиск у скронях")
    }

    func testSurroundingWhitespaceIsRemoved() {
        XCTAssertEqual(WellbeingTag.storedName(from: "  Втома\n"), "Втома")
    }

    func testAWhitespaceOnlyNameIsNotAName() {
        XCTAssertNil(WellbeingTag.storedName(from: ""))
        XCTAssertNil(WellbeingTag.storedName(from: "   \n "))
    }

    func testALongUnbrokenWordIsCutToTheBound() {
        // The case this exists for: one word long enough to draw its chip off the edge of the
        // check-in sheet.
        let typed = "Ааппппевееошуошошщуок122345566777888888888888888888888888"
        let stored = WellbeingTag.storedName(from: typed)

        XCTAssertEqual(stored?.count, WellbeingTag.maximumNameLength)
        XCTAssertEqual(stored, String(typed.prefix(WellbeingTag.maximumNameLength)))
    }

    func testANameExactlyAtTheBoundIsKeptWhole() {
        let typed = String(repeating: "а", count: WellbeingTag.maximumNameLength)

        XCTAssertEqual(WellbeingTag.storedName(from: typed), typed)
    }

    func testACutThatLandsOnASpaceDoesNotStoreATrailingOne() {
        // A stored name ending in a space would not match itself when the user typed it back.
        let typed = String(repeating: "а", count: WellbeingTag.maximumNameLength - 1) + " далі"
        let stored = WellbeingTag.storedName(from: typed)

        XCTAssertEqual(stored, String(repeating: "а", count: WellbeingTag.maximumNameLength - 1))
    }

    func testTheBoundIsCountedInCharactersNotScalars() {
        // A grapheme cluster is one character to a reader, and cutting by scalar would leave
        // the combining mark of the letter it was cut from at the end of the name.
        let typed = String(repeating: "й", count: WellbeingTag.maximumNameLength + 10)
            .decomposedStringWithCanonicalMapping
        let stored = WellbeingTag.storedName(from: typed)

        XCTAssertEqual(stored?.count, WellbeingTag.maximumNameLength)
    }

    func testTheBoundAdmitsTheNamesPeopleActuallyWrite() {
        // Guards the bound from being tightened to something a real multi-word tag would hit.
        XCTAssertGreaterThanOrEqual(WellbeingTag.maximumNameLength,
                                    "Тиск у скронях після поганого сну".count)
    }
}
