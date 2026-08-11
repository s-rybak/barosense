import Foundation

/// Storage for the language row in Settings.
///
/// Synchronous, unlike the data stores: this is one small value read during the first
/// paint of every screen, and an `async` read would make the root view flash the system
/// language before settling on the chosen one.
protocol LanguagePreferenceStore: Sendable {

    /// The stored choice, or `.system` when the user has never picked one.
    func selection() -> LanguageSelection

    /// Records the choice.
    func setSelection(_ selection: LanguageSelection)
}

/// `UserDefaults`-backed `LanguagePreferenceStore`.
///
/// Writes the choice twice, to two different keys, because they do two different jobs:
///
/// - `Keys.selection` is what this app reads back. It keeps `.system` distinguishable
///   from "pinned to the language the system happens to be", which `AppleLanguages`
///   alone cannot express.
/// - `AppleLanguages` is what **iOS** reads. It decides which `.lproj` the bundle resolves
///   by default and which language system-supplied UI appears in — the share sheet, the
///   HealthKit sheet, `Locale.current`-driven formatting outside SwiftUI. It takes effect
///   at the next launch, not immediately; the immediate change comes from the environment
///   locale the root view injects.
///
/// The preference holds no personal data, which is why "delete my data" leaves it alone —
/// see `BarosenseDataEraser`.
struct UserDefaultsLanguagePreferenceStore: LanguagePreferenceStore {

    private enum Keys {
        /// Stored value is `"system"` or an `AppLanguage.rawValue`.
        static let selection = "barosense.settings.language"
        /// Apple's own key. Not ours to rename.
        static let appleLanguages = "AppleLanguages"
    }

    /// `nonisolated(unsafe)` because `UserDefaults` is documented thread-safe but is not
    /// annotated `Sendable` in the SDK. The alternative — dropping `Sendable` from the
    /// protocol — would make every future off-main read of this preference a new problem,
    /// and there is nothing unsafe here to hide.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func selection() -> LanguageSelection {
        guard let stored = defaults.string(forKey: Keys.selection) else { return .system }
        guard let language = AppLanguage(rawValue: stored) else { return .system }
        return .fixed(language)
    }

    func setSelection(_ selection: LanguageSelection) {
        switch selection.pinnedLanguage {
        case nil:
            defaults.removeObject(forKey: Keys.selection)
            // Removed rather than set to the resolved language: leaving a one-element
            // override behind would freeze the app on today's system language and quietly
            // stop following the device.
            defaults.removeObject(forKey: Keys.appleLanguages)
        case let language?:
            defaults.set(language.rawValue, forKey: Keys.selection)
            defaults.set([language.languageCode], forKey: Keys.appleLanguages)
        }
    }
}
