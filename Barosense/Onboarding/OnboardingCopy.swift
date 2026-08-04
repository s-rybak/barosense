import SwiftUI

// Display text for the domain values onboarding collects.
//
// It lives in the app target, not in `Shared/`: `Shared/` is UI-free, and these strings
// are app copy bound by `.claude/skills/appstore_compliance/SKILL.md`. Keeping them in
// one file means a copy review reads one file rather than six views.
//
// Every string here is a `LocalizedStringKey`, so the literal is the base-language text
// and `Localizable.xcstrings` carries the translations.

// MARK: - Profile

extension Gender {
    var label: LocalizedStringKey {
        switch self {
        case .female: "Woman"
        case .male: "Man"
        case .other: "Other"
        }
    }
}

// MARK: - Pattern

extension EpisodeFrequency {
    var label: LocalizedStringKey {
        switch self {
        case .daily: "Every day"
        case .severalTimesPerWeek: "Several times a week"
        case .weekly: "Once a week"
        case .lessOften: "Less often"
        }
    }
}

extension EpisodeDuration {
    var label: LocalizedStringKey {
        switch self {
        case .underOneHour: "< 1 h"
        case .oneToSixHours: "1–6 h"
        case .sixToTwentyFourHours: "6–24 h"
        case .overOneDay: "> 24 h"
        }
    }
}

// MARK: - Tags

extension WellbeingTag {

    /// What to show for this tag.
    ///
    /// A seeded tag the user has not renamed is app copy, so it is looked up and
    /// translated. Anything else — a renamed seed, or a tag the user created — is their
    /// own text and is rendered verbatim: running user input through a localisation
    /// lookup would silently swap the word of anyone who happened to type one of ours.
    var label: Text {
        guard case .seeded(let slug) = id,
              let key = Self.seededLabel(forSlug: slug),
              name == Self.shippedDefaultName(forSlug: slug)
        else {
            return Text(verbatim: name)
        }
        return Text(key)
    }

    /// Localisable text for each shipped slug. Slugs mirror `WellbeingTag.seeds`; one
    /// missing here falls back to the stored name, which is the base-language default.
    ///
    /// A function rather than a static dictionary: `LocalizedStringKey` is not `Sendable`,
    /// so a stored one is a concurrency error under the Swift 6 language mode.
    private static func seededLabel(forSlug slug: String) -> LocalizedStringKey? {
        switch slug {
        case "headache": "Headache" // barosense:copy-allow default wellbeing tag
        case "migraine": "Migraine" // barosense:copy-allow default wellbeing tag
        case "fatigue": "Fatigue"
        case "joints": "Joint pain"
        case "sleep": "Disrupted sleep"
        case "mood": "Mood swings"
        case "dizziness": "Dizziness"
        default: nil
        }
    }

    private static func shippedDefaultName(forSlug slug: String) -> String? {
        seeds.first { $0.id == .seeded(slug) }?.name
    }
}
