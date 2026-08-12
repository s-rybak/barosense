import Foundation

/// A language Barosense ships a translation for.
///
/// The raw value is the `.lproj` folder name in the built bundle *and* the key written to
/// `AppleLanguages`, so it is storage identity: renaming a case orphans the stored
/// preference of every install that picked it.
///
/// Two cases today. Adding a third means adding the language to `Localizable.xcstrings`
/// **and** to the target's `knownRegions` — a case with no translations resolves to the
/// base language and looks like a bug rather than a missing string.
enum AppLanguage: String, CaseIterable, Codable, Sendable {

    /// The base language: every `LocalizedStringKey` literal in the source is English, so
    /// this is the one language that cannot have a missing translation.
    case english = "en"

    case ukrainian = "uk"

    /// BCP-47 language code. Named rather than used as `rawValue` at call sites, so the
    /// two meanings of the raw value stay visible.
    var languageCode: String { rawValue }
}

/// What the user picked in Settings › Language.
///
/// `.system` is a distinct state, not "whatever the system happened to be when they
/// installed": someone who never touches this row and then switches their phone to
/// Ukrainian expects the app to follow, and a resolved value stored at first launch would
/// not.
enum LanguageSelection: Hashable, Codable, Sendable {

    /// Follow the device's language order. The default.
    case system

    /// Pin the app to one language regardless of the device.
    case fixed(AppLanguage)
}

extension LanguageSelection {

    /// The language to actually render in.
    ///
    /// `preferredLanguages` is injected rather than read from `Locale` inside, so the
    /// resolution rule is testable without a device set to Ukrainian.
    ///
    /// Falls back to `.english` when the device asks for a language this app does not
    /// ship: that is the base language, and the alternative — showing partly translated
    /// text — is worse than showing one language consistently.
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .fixed(let language):
            return language
        case .system:
            return AppLanguage.firstSupported(in: preferredLanguages) ?? .english
        }
    }

    /// The pinned language, or `nil` when following the system. What the preference store
    /// writes to `AppleLanguages`.
    var pinnedLanguage: AppLanguage? {
        switch self {
        case .system: nil
        case .fixed(let language): language
        }
    }
}

extension AppLanguage {

    /// The first shipped language in the device's preference order.
    ///
    /// Matches on the language subtag only: iOS hands back tags like `uk-UA` and
    /// `en-GB`, and a whole-string comparison would miss every one of them.
    static func firstSupported(in preferredLanguages: [String]) -> AppLanguage? {
        for tag in preferredLanguages {
            let code = Locale.Language(identifier: tag).languageCode?.identifier
            if let match = AppLanguage(rawValue: code ?? "") {
                return match
            }
        }
        return nil
    }

    /// Locale to render dates, numbers and localised strings against.
    ///
    /// Region-less on purpose. The user picked a language, not a country, and pinning a
    /// region here would also change date order and number separators for someone who
    /// only wanted the words to change.
    var locale: Locale { Locale(identifier: languageCode) }
}
