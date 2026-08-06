import Foundation
import SwiftData

/// Durable row for `UserProfile`.
///
/// Deliberately a flat record of primitives rather than a nested `Codable` blob: SwiftData
/// stores a `Codable` property as opaque bytes, which cannot be queried or migrated
/// field-by-field. The enums are held by their frozen raw values and mapped back on read.
///
/// Not `Sendable`, and it must not become so. `@Model` instances stay inside the store
/// actor; callers get the `UserProfile` value type.
@Model
final class StoredUserProfile {

    var displayName: String?
    var ageYears: Int?
    /// `Gender.rawValue`. An unrecognised string reads back as `nil` rather than
    /// crashing, so a row written by a newer build downgrades instead of taking the app
    /// with it.
    var genderRawValue: String?
    /// `EpisodeFrequency.rawValue`, same downgrade rule.
    var episodeFrequencyRawValue: String?
    /// `EpisodeDuration.rawValue`, same downgrade rule.
    var typicalEpisodeDurationRawValue: String?

    var termsAcceptedAt: Date?
    var healthAccessRequestedAt: Date?
    var onboardingCompletedAt: Date?

    init(profile: UserProfile) {
        apply(profile)
    }

    /// Overwrites every field from `profile`. Every assignment is unconditional: a field
    /// the user cleared has to be cleared in storage too.
    func apply(_ profile: UserProfile) {
        displayName = profile.displayName
        ageYears = profile.ageYears
        genderRawValue = profile.gender?.rawValue
        episodeFrequencyRawValue = profile.episodeFrequency?.rawValue
        typicalEpisodeDurationRawValue = profile.typicalEpisodeDuration?.rawValue
        termsAcceptedAt = profile.termsAcceptedAt
        healthAccessRequestedAt = profile.healthAccessRequestedAt
        onboardingCompletedAt = profile.onboardingCompletedAt
    }

    var profile: UserProfile {
        UserProfile(
            displayName: displayName,
            ageYears: ageYears,
            gender: genderRawValue.flatMap(Gender.init(rawValue:)),
            episodeFrequency: episodeFrequencyRawValue.flatMap(EpisodeFrequency.init(rawValue:)),
            typicalEpisodeDuration: typicalEpisodeDurationRawValue
                .flatMap(EpisodeDuration.init(rawValue:)),
            termsAcceptedAt: termsAcceptedAt,
            healthAccessRequestedAt: healthAccessRequestedAt,
            onboardingCompletedAt: onboardingCompletedAt
        )
    }
}

/// On-disk `UserProfileStore`.
///
/// A `@ModelActor` because `ModelContext` is not `Sendable` and the project builds with
/// complete strict concurrency: the actor owns its context, and only value types leave.
@ModelActor
actor SwiftDataUserProfileStore: UserProfileStore {

    func profile() throws -> UserProfile? {
        try storedProfiles().first?.profile
    }

    func save(_ profile: UserProfile) throws {
        let stored = try storedProfiles()

        if let existing = stored.first {
            existing.apply(profile)
            // A duplicate row would be a bug rather than a normal state, but crashing on
            // one turns a recoverable bug into a launch failure. Collapse it instead, so
            // the store repairs itself on the next write.
            for duplicate in stored.dropFirst() {
                modelContext.delete(duplicate)
            }
        } else {
            modelContext.insert(StoredUserProfile(profile: profile))
        }
        try modelContext.save()
    }

    func deleteProfile() throws {
        let stored = try storedProfiles()
        guard !stored.isEmpty else { return }

        for row in stored {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// Every stored profile row — normally zero or one.
    ///
    /// Fetched unfiltered rather than through a `#Predicate`: the macro expansion
    /// captures a `KeyPath` into a non-`Sendable` `@Model` type, which is a warning today
    /// and an error under the Swift 6 language mode the project is heading for. There is
    /// at most one row, so there is nothing for a predicate to narrow anyway.
    private func storedProfiles() throws -> [StoredUserProfile] {
        try modelContext.fetch(FetchDescriptor<StoredUserProfile>())
    }
}
