import XCTest
@testable import Barosense

final class UserProfileTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - Storage format

    func testEnumRawValuesAreFrozen() {
        // Raw values are what lands in the store. Renaming one silently reads back as
        // `nil` on every existing install, so it has to fail a test rather than a review.
        XCTAssertEqual(Gender.allCases.map(\.rawValue), ["female", "male", "other"])

        XCTAssertEqual(EpisodeFrequency.allCases.map(\.rawValue),
                       ["daily", "severalTimesPerWeek", "weekly", "lessOften"])

        XCTAssertEqual(EpisodeDuration.allCases.map(\.rawValue),
                       ["underOneHour", "oneToSixHours", "sixToTwentyFourHours", "overOneDay"])
    }

    func testProfileSurvivesACodableRoundTrip() throws {
        let profile = UserProfile(displayName: "Sam",
                                  ageYears: 34,
                                  gender: .female,
                                  episodeFrequency: .severalTimesPerWeek,
                                  typicalEpisodeDuration: .oneToSixHours,
                                  termsAcceptedAt: referenceDate,
                                  healthAccessRequestedAt: referenceDate,
                                  onboardingCompletedAt: referenceDate)

        let decoded = try JSONDecoder().decode(
            UserProfile.self,
            from: JSONEncoder().encode(profile)
        )

        XCTAssertEqual(decoded, profile)
    }

    // MARK: - Completion

    func testAnEmptyProfileHasNotCompletedOnboarding() {
        XCTAssertFalse(UserProfile().hasCompletedOnboarding)
        XCTAssertFalse(UserProfile().hasAcceptedTerms)
    }

    func testCompletionIsCarriedByTheTimestampAlone() {
        // Everything else being blank must not make a finished profile look unfinished:
        // every answer in the flow except the terms box is skippable.
        let profile = UserProfile(onboardingCompletedAt: referenceDate)

        XCTAssertTrue(profile.hasCompletedOnboarding)
    }

    // MARK: - Age

    func testSupportedAgeRangeExcludesImplausibleEntries() {
        XCTAssertFalse(UserProfile.supportedAgeYears.contains(0))
        XCTAssertFalse(UserProfile.supportedAgeYears.contains(150))
        XCTAssertTrue(UserProfile.supportedAgeYears.contains(34))
    }

    // MARK: - Store contract

    func testSavedProfileIsReadBack() async throws {
        let store: any UserProfileStore = InMemoryUserProfileStore()
        let profile = UserProfile(displayName: "Sam", ageYears: 34)

        try await store.save(profile)

        let read = try await store.profile()
        XCTAssertEqual(read, profile)
    }

    func testProfileIsNilBeforeAnythingIsWritten() async throws {
        let store: any UserProfileStore = InMemoryUserProfileStore()

        let read = try await store.profile()
        XCTAssertNil(read)
    }

    func testSavingReplacesRatherThanAccumulates() async throws {
        let store: any UserProfileStore = InMemoryUserProfileStore()

        try await store.save(UserProfile(displayName: "Sam", ageYears: 34))
        try await store.save(UserProfile(displayName: "Alex"))

        // The second write cleared the age. A merge would have kept it.
        let read = try await store.profile()
        XCTAssertEqual(read, UserProfile(displayName: "Alex"))
    }

    func testDeletingAnAbsentProfileIsNotAnError() async throws {
        let store: any UserProfileStore = InMemoryUserProfileStore()

        try await store.deleteProfile()

        let read = try await store.profile()
        XCTAssertNil(read)
    }
}
