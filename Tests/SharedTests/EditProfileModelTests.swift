import XCTest
@testable import Barosense

/// The profile editor: nothing is written until Save, and Save must not lose the fields the
/// screen does not show.
@MainActor
final class EditProfileModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Loading

    func testLoadFillsEveryFieldFromTheStoredProfile() async {
        let stored = UserProfile(displayName: "Olena",
                                 ageYears: 34,
                                 gender: .female,
                                 episodeFrequency: .daily,
                                 typicalEpisodeDuration: .oneToSixHours,
                                 onboardingCompletedAt: now)
        let model = makeModel(profile: stored)

        await model.load()

        XCTAssertEqual(model.displayName, "Olena")
        XCTAssertEqual(model.ageText, "34")
        XCTAssertEqual(model.gender, .female)
        XCTAssertEqual(model.episodeFrequency, .daily)
        XCTAssertEqual(model.typicalEpisodeDuration, .oneToSixHours)
        XCTAssertEqual(model.tags.count, WellbeingTag.seeds.count)
    }

    // MARK: - Validation

    func testSaveIsOffUntilSomethingChanges() async {
        let model = makeModel(profile: UserProfile(displayName: "Olena"))
        await model.load()

        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(model.canSave)

        model.displayName = "Olena K."

        XCTAssertTrue(model.hasChanges)
        XCTAssertTrue(model.canSave)
    }

    func testAnAgeOutsideTheSupportedRangeBlocksSave() async {
        let model = makeModel(profile: UserProfile(displayName: "Olena"))
        await model.load()

        model.ageText = "7"

        XCTAssertFalse(model.isAgeValid)
        XCTAssertFalse(model.canSave)
    }

    /// Blank is a valid answer — every field on this screen is optional.
    func testAClearedAgeIsValid() async {
        let model = makeModel(profile: UserProfile(displayName: "Olena", ageYears: 34))
        await model.load()

        model.ageText = ""

        XCTAssertTrue(model.isAgeValid)
        XCTAssertNil(model.ageYears)
        XCTAssertTrue(model.canSave)
    }

    /// The vocabulary may not be emptied here, for the same reason onboarding insists on
    /// one: a check-in with nothing to tag has no label to learn from.
    func testAnEmptyVocabularyBlocksSave() async {
        let model = makeModel(profile: UserProfile(displayName: "Olena"))
        await model.load()

        for tag in model.tags {
            model.removeTag(tag.id)
        }

        XCTAssertFalse(model.hasTags)
        XCTAssertFalse(model.canSave)
    }

    // MARK: - Tags

    func testRemovingATagDoesNotTouchTheStoreUntilSave() async throws {
        let tags = InMemoryWellbeingTagStore(WellbeingTag.seeds)
        let model = makeModel(profile: UserProfile(displayName: "Olena"), tagStore: tags)
        await model.load()
        let removed = try XCTUnwrap(model.tags.first)

        model.removeTag(removed.id)

        let untouched = try await tags.activeTags()
        XCTAssertEqual(untouched.count, WellbeingTag.seeds.count)

        await model.save()

        let active = try await tags.activeTags()
        let all = try await tags.allTags()
        XCTAssertEqual(active.count, WellbeingTag.seeds.count - 1)
        XCTAssertFalse(active.contains { $0.id == removed.id })
        // Archived, not deleted: old check-ins still point at it.
        XCTAssertEqual(all.count, WellbeingTag.seeds.count)
    }

    func testAnAddedTagIsWrittenWithAUserIdentity() async throws {
        let tags = InMemoryWellbeingTagStore(WellbeingTag.seeds)
        let model = makeModel(profile: UserProfile(displayName: "Olena"), tagStore: tags)
        await model.load()

        model.beginAddingTag()
        model.newTagName = "Neck tension"
        model.commitNewTag()
        await model.save()

        let added = try await tags.activeTags().first { $0.name == "Neck tension" }
        let tag = try XCTUnwrap(added)
        // Never a seeded slug: those are shipped identity, and a user-minted one would
        // collide with a future release that ships the same slug.
        guard case .user = tag.id else {
            return XCTFail("expected a user identity, got \(tag.id)")
        }
    }

    func testANameThatIsAlreadyInTheListIsIgnored() async {
        let model = makeModel(profile: UserProfile(displayName: "Olena"))
        await model.load()
        let before = model.tags.count
        let existing = model.tags[0].name

        model.beginAddingTag()
        model.newTagName = existing.uppercased()
        model.commitNewTag()

        XCTAssertEqual(model.tags.count, before)
    }

    func testABlankTagNameIsIgnored() async {
        let model = makeModel(profile: UserProfile(displayName: "Olena"))
        await model.load()
        let before = model.tags.count

        model.beginAddingTag()
        model.newTagName = "   "
        model.commitNewTag()

        XCTAssertEqual(model.tags.count, before)
        XCTAssertFalse(model.isAddingTag)
    }

    // MARK: - Saving

    /// The editor shows neither of these, and building a fresh `UserProfile` on save would
    /// clear `onboardingCompletedAt` — dropping the user back into onboarding on next launch.
    func testSavingKeepsTheFieldsTheScreenDoesNotShow() async throws {
        let accepted = now.addingTimeInterval(-86_400)
        let profiles = InMemoryUserProfileStore(UserProfile(displayName: "Olena",
                                                            termsAcceptedAt: accepted,
                                                            onboardingCompletedAt: accepted))
        let model = makeModel(profileStore: profiles)
        await model.load()

        model.displayName = "Olena K."
        await model.save()

        let stored = try await profiles.profile()
        let saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.displayName, "Olena K.")
        XCTAssertEqual(saved.termsAcceptedAt, accepted)
        XCTAssertEqual(saved.onboardingCompletedAt, accepted)
    }

    func testAWhitespaceOnlyNameIsStoredAsNoName() async throws {
        let profiles = InMemoryUserProfileStore(UserProfile(displayName: "Olena"))
        let model = makeModel(profileStore: profiles)
        await model.load()

        model.displayName = "   "
        await model.save()

        let saved = try await profiles.profile()
        XCTAssertNil(saved?.displayName)
    }

    func testSavingClearsTheChangeFlagSoSaveGoesDimAgain() async {
        let model = makeModel(profile: UserProfile(displayName: "Olena"))
        await model.load()
        model.displayName = "Olena K."

        await model.save()

        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(model.canSave)
    }

    func testARefusedWriteKeepsTheEditsAndReportsIt() async {
        let model = makeModel(profileStore: RefusingUserProfileStore())
        await model.load()
        model.displayName = "Olena K."

        await model.save()

        XCTAssertEqual(model.failure, .couldNotSave)
        XCTAssertEqual(model.displayName, "Olena K.")
        XCTAssertTrue(model.hasChanges)
    }

    /// The avatar tracks the field as it is typed, not what is stored — the point of
    /// showing it above the name field.
    func testTheInitialFollowsTheTypedName() async {
        let model = makeModel(profile: UserProfile())
        await model.load()

        XCTAssertEqual(model.initial, "")
        model.displayName = "olena"
        XCTAssertEqual(model.initial, "O")
    }

    // MARK: - Avatar

    func testPickingAPhotoStoresItDownscaled() async throws {
        let model = makeModel()
        await model.load()

        await model.setAvatar(try SampleImage.jpeg(width: 1200, height: 900))

        let stored = try XCTUnwrap(model.avatarImageData)
        XCTAssertEqual(try SampleImage.pixelSize(of: stored).width,
                       ProfileAvatarEncoder.maxPixelSize)
        XCTAssertFalse(model.isEncodingAvatar)
    }

    func testAPhotoThatCannotBeReadKeepsTheOneAlreadyThere() async throws {
        let model = makeModel()
        await model.load()
        await model.setAvatar(try SampleImage.jpeg(width: 400, height: 400))
        let kept = model.avatarImageData

        await model.setAvatar(Data("not an image".utf8))

        XCTAssertEqual(model.failure, .couldNotReadPhoto)
        XCTAssertEqual(model.avatarImageData, kept)
    }

    /// The re-encode runs off the main actor, which is what makes this reachable at all:
    /// Remove stays tappable while a picked photo is still being encoded, and the encode
    /// finishing afterwards must not put the photo back.
    func testRemovingThePhotoBeatsAPickThatIsStillEncoding() async throws {
        let model = makeModel()
        await model.load()
        let picked = try SampleImage.jpeg(width: 4000, height: 3000)

        let encoding = Task { await model.setAvatar(picked) }
        while !model.isEncodingAvatar { await Task.yield() }
        model.removeAvatar()
        await encoding.value

        XCTAssertNil(model.avatarImageData)
        XCTAssertFalse(model.isEncodingAvatar)
    }

    /// Save writes `avatarImageData` as it stands, so it has to wait for the photo the user
    /// just picked rather than write the profile without it.
    func testSaveIsHeldUntilThePickedPhotoIsEncoded() async throws {
        let model = makeModel()
        await model.load()
        let picked = try SampleImage.jpeg(width: 4000, height: 3000)

        let encoding = Task { await model.setAvatar(picked) }
        while !model.isEncodingAvatar { await Task.yield() }
        XCTAssertFalse(model.canSave)

        await encoding.value

        XCTAssertTrue(model.canSave)
    }

    // MARK: - Helpers

    private func makeModel(profile: UserProfile = UserProfile(),
                           profileStore: (any UserProfileStore)? = nil,
                           tagStore: any WellbeingTagStore = InMemoryWellbeingTagStore(WellbeingTag.seeds),
                           onSaved: @escaping () -> Void = {}) -> EditProfileModel {
        let dependencies = SettingsDependencies(
            profileStore: profileStore ?? InMemoryUserProfileStore(profile),
            tagStore: tagStore,
            checkInStore: InMemoryCheckInStore(),
            healthLog: InMemoryHealthSampleStore(),
            pressureLog: InMemoryPressureSampleStore(),
            locationEpochs: InMemoryPressureLocationEpochStore(),
            weatherArchive: InMemoryWeatherForecastStore(),
            notificationLog: InMemoryNotificationStore(),
            healthAccess: UnavailableHealthAccessReporter(),
            locationAccess: UnavailableLocationAccessReporter()
        )
        return EditProfileModel(dependencies: dependencies, onSaved: onSaved)
    }
}

// MARK: - Doubles

private struct StoreRefused: Error {}

/// Reads back an empty profile and refuses every write.
private struct RefusingUserProfileStore: UserProfileStore {
    func profile() async throws -> UserProfile? { UserProfile(displayName: "Olena") }
    func save(_ profile: UserProfile) async throws { throw StoreRefused() }
    func deleteProfile() async throws { throw StoreRefused() }
}
