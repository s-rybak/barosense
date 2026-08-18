import Foundation

/// The words each notification kind carries, in the language the user picked in Settings.
///
/// In the app target rather than in `Shared/` because this is copy, and because resolving it
/// needs the app bundle. `Shared/` stays UI-free and free of anything the user reads.
///
/// ## Why the bundle is opened by hand
///
/// Every other string in the app is a `LocalizedStringKey` that SwiftUI resolves against the
/// environment locale, which is how a language change repaints the whole app in one frame.
/// A notification has no environment: it is built here and handed to iOS to display later.
/// `String(localized:)` would resolve against `Bundle.main`'s language, which follows the
/// `AppleLanguages` write in `UserDefaultsLanguagePreferenceStore` and therefore lags the
/// user's choice by one launch — so someone who switched to Ukrainian this morning would get
/// an English reminder this evening.
///
/// Loading the chosen language's `.lproj` directly is the same mechanism
/// `WellbeingTag.shippedCopy` uses, for the same reason: it is the only way to read a named
/// translation rather than the bundle's current one.
///
/// One caveat worth stating: the text is fixed when the notification is handed to the system,
/// up to two days ahead (`NotificationCoordinator.schedulingHorizonHours`). A language change
/// in that window leaves an already-scheduled reminder in the old language. The in-app list
/// is unaffected — it renders from the kind, through the environment, like everything else.
struct LocalizedNotificationContent: NotificationContentProviding {

    /// Base-language copy, which is also the catalogue key. A language with no translation of
    /// it falls back to exactly this text.
    private enum Copy {
        static let checkInReminderTitle = "How are you feeling?"
        static let checkInReminderBody = "A short check-in keeps your history complete."
    }

    private let languages: any LanguagePreferenceStore

    /// Reads the preference store rather than `LanguageController`, which is `@MainActor`
    /// while this is called from `NotificationCoordinator`'s executor. Same stored value, same
    /// resolution rule — see `LanguageSelection.resolved()`.
    init(languages: any LanguagePreferenceStore = UserDefaultsLanguagePreferenceStore()) {
        self.languages = languages
    }

    func content(for kind: AppNotificationKind) -> NotificationContent {
        let language = languages.selection().resolved()

        switch kind {
        case .checkInReminder:
            return NotificationContent(
                title: string(Copy.checkInReminderTitle, in: language),
                body: string(Copy.checkInReminderBody, in: language)
            )
        }
    }

    /// The shipped copy for `key` in one named language, falling back to the key itself —
    /// which is the base-language text — for a language with no bundle or no translation of it.
    private func string(_ key: String, in language: AppLanguage) -> String {
        guard let path = Bundle.main.path(forResource: language.languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
