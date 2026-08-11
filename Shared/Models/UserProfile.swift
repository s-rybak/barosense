import Foundation

/// How the user describes themselves. Personalisation input, never a gate: the forecast
/// has to work for someone who skipped every field here.
///
/// Raw values are persisted and are part of the storage format — do not rename them.
/// The display text for each case is UI copy and lives in the app target, not here.
enum Gender: String, CaseIterable, Codable, Sendable {
    case female
    case male
    case other
}

/// How often the user says a harder period comes around.
///
/// Coarse buckets rather than a number: this is recalled, not measured, and a free-form
/// count would imply a precision the answer does not have. Its only job is to give the
/// population prior something to lean on before there is personal history
/// (`CLAUDE.md`, constraint 5).
enum EpisodeFrequency: String, CaseIterable, Codable, Sendable {
    case daily
    case severalTimesPerWeek
    case weekly
    case lessOften
}

/// How long a harder period typically lasts, in the same coarse-bucket spirit as
/// `EpisodeFrequency`.
///
/// Bounds the window a future advance warning is worth covering: someone whose episodes
/// run under an hour and someone whose run past a day are not served by the same lead
/// time.
enum EpisodeDuration: String, CaseIterable, Codable, Sendable {
    case underOneHour
    case oneToSixHours
    case sixToTwentyFourHours
    case overOneDay
}

/// Everything onboarding collects about the person using the app, plus the record that
/// onboarding happened at all.
///
/// One value, one stored row. Onboarding is the only thing that writes a complete
/// profile, and "did the user finish onboarding" is a property of the profile rather than
/// a separate flag — two records could disagree, one cannot.
///
/// This is health-adjacent personal data. It stays on device (`CLAUDE.md`, constraint 2):
/// the durable store is built with CloudKit explicitly off, and no field here may join an
/// outbound payload.
///
/// Every field is optional because every field is skippable. A half-finished profile is a
/// normal state, not a defect.
struct UserProfile: Hashable, Codable, Sendable {

    /// What the user wants to be called. Free text — same rule as `CheckIn.note`: never a
    /// model feature, never in an outbound payload.
    var displayName: String?

    /// Age in whole years, as reported. `nil` when not given.
    ///
    /// Stored as the number the user typed rather than as a birth date: a birth date is
    /// more identifying than the question needs, and nothing here has to stay correct on
    /// a birthday.
    var ageYears: Int?

    var gender: Gender?

    /// The avatar the user picked, already downscaled and JPEG-encoded by the picker.
    /// `nil` means fall back to the initial of `displayName`, which is what the design
    /// draws before a photo is chosen.
    ///
    /// Bytes rather than a file path: a path is a second thing to keep in step with the
    /// row, and "delete my data" would have to know about a directory as well as a store.
    /// Kept small at the boundary — `ProfileAvatarEncoder` caps it — so this stays a
    /// thumbnail and never a full camera capture.
    ///
    /// Personal data like every other field here: on-device only, never in an outbound
    /// payload, never a model feature.
    var avatarImageData: Data?

    var episodeFrequency: EpisodeFrequency?

    var typicalEpisodeDuration: EpisodeDuration?

    /// When the user accepted the terms and the privacy policy. `nil` means they have
    /// not, and the app must not proceed past that step.
    var termsAcceptedAt: Date?

    /// When the user asked to connect Apple Health, if they did.
    ///
    /// Records the user's *intent*, not an authorisation result. iOS does not reveal
    /// whether a read type was granted, so nothing may interpret this as "access granted"
    /// (`.claude/skills/healthkit_permissions/SKILL.md`).
    var healthAccessRequestedAt: Date?

    /// When the user finished onboarding. The single source of truth for whether the
    /// flow still has to be shown.
    var onboardingCompletedAt: Date?

    init(displayName: String? = nil,
         ageYears: Int? = nil,
         gender: Gender? = nil,
         avatarImageData: Data? = nil,
         episodeFrequency: EpisodeFrequency? = nil,
         typicalEpisodeDuration: EpisodeDuration? = nil,
         termsAcceptedAt: Date? = nil,
         healthAccessRequestedAt: Date? = nil,
         onboardingCompletedAt: Date? = nil) {
        self.displayName = displayName
        self.ageYears = ageYears
        self.gender = gender
        self.avatarImageData = avatarImageData
        self.episodeFrequency = episodeFrequency
        self.typicalEpisodeDuration = typicalEpisodeDuration
        self.termsAcceptedAt = termsAcceptedAt
        self.healthAccessRequestedAt = healthAccessRequestedAt
        self.onboardingCompletedAt = onboardingCompletedAt
    }
}

extension UserProfile {

    /// Ages the app will store. A value outside this range is a typo or a mis-tap, and
    /// letting one through would put a nonsense number into the population prior.
    static let supportedAgeYears = 13...120

    var hasCompletedOnboarding: Bool { onboardingCompletedAt != nil }

    var hasAcceptedTerms: Bool { termsAcceptedAt != nil }
}
