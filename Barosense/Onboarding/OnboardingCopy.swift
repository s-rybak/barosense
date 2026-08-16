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
    ///
    /// The seeded half is a `LocalizedStringKey` rather than a string resolved here, so that
    /// SwiftUI looks it up against the environment's locale. `LanguageController` feeds the
    /// picked language into that environment and expects the whole tree to repaint in the
    /// same frame; a string resolved through `Locale.current` would instead keep the old
    /// language until the next launch, leaving these chips in English beside a Ukrainian
    /// section header.
    var label: Text {
        guard let key = seededCopyKey else { return Text(verbatim: name) }
        return Text(LocalizedStringKey(key))
    }

    /// Whether `typedName` is this tag under one of the names it is drawn by.
    ///
    /// Exists because the app has to *match* what the user reads, not only draw it: a
    /// Ukrainian reader typing "Втома" into the new-tag field is naming the seeded `fatigue`
    /// tag, whose stored `name` is the base-language "Fatigue". Matching on `name` alone would
    /// file that as a second tag with the same meaning, and the two would then split every
    /// count the History card and the model are built on.
    ///
    /// Checks every language the app ships rather than only the one on screen. Settings lets
    /// the language be switched at any time, so the vocabulary a user builds up spans both:
    /// someone who added tags in English and later switched to Ukrainian still must not be
    /// able to create a second "Fatigue" by typing "Втома".
    func isNamed(_ typedName: String) -> Bool {
        drawnNames.contains { $0.localizedCaseInsensitiveCompare(typedName) == .orderedSame }
    }

    /// Every string this tag can appear as: the stored name, plus each shipped translation
    /// when it is a seeded tag still carrying its shipped name.
    private var drawnNames: [String] {
        guard let key = seededCopyKey else { return [name] }
        return [name] + AppLanguage.allCases.compactMap { Self.shippedCopy(key, in: $0) }
    }

    /// The shipped copy for `key` in one named language.
    ///
    /// A *named* language rather than the environment's is what makes the difference between
    /// recognising "Втома" and filing a second tag for it. The `.lproj` lookup that does it —
    /// and why it is not `String(localized:locale:)` — lives on `AppLanguage.shippedCopy`,
    /// shared with the notification copy, which needs the same thing for the same reason.
    ///
    /// `nil` for a language with no bundle, and the key itself for one with no translation of
    /// it. Both fall back to matching the base-language text, which `name` already covers.
    private static func shippedCopy(_ key: String, in language: AppLanguage) -> String? {
        language.shippedCopy(forKey: key)
    }

    /// The base-language copy for a seeded tag the user has not renamed, and `nil` for
    /// everything else — a renamed seed or a tag the user wrote, whose text is theirs and is
    /// never put through a lookup.
    ///
    /// A plain `String` because it is needed as two different types: `LocalizedStringKey` to
    /// draw through the environment, and `String.LocalizationValue` to resolve against a named
    /// locale. Keeping one switch means the two cannot drift apart.
    private var seededCopyKey: String? {
        guard case .seeded(let slug) = id,
              let key = Self.seededLabel(forSlug: slug),
              name == Self.shippedDefaultName(forSlug: slug)
        else {
            return nil
        }
        return key
    }

    /// Localisable text for each shipped slug. Slugs mirror `WellbeingTag.seeds`; one
    /// missing here falls back to the stored name, which is the base-language default.
    private static func seededLabel(forSlug slug: String) -> String? {
        switch slug {
        case "headache": "Headache" // barosense:copy-allow default wellbeing tag
        case "migraine": "Severe headache" // barosense:copy-allow frozen storage slug
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
