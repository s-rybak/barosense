import SwiftUI

/// Holds the language the app is rendering in, and writes changes to it back to storage.
///
/// One instance, owned by the composition root, so a change made in Settings reaches every
/// view in the same frame. The stored preference alone could not do that: it is read once
/// per launch, and a view has no way to know it changed.
///
/// The switch takes effect immediately for everything Barosense draws, because the root
/// view feeds `locale` into the environment and SwiftUI resolves every
/// `LocalizedStringKey` against it. What it does **not** move until the next launch is
/// iOS's own idea of the app's language — system sheets, and `Locale.current` outside the
/// SwiftUI environment. That is what the `AppleLanguages` write in
/// `UserDefaultsLanguagePreferenceStore` is for.
@MainActor
@Observable
final class LanguageController {

    private(set) var selection: LanguageSelection

    private let store: any LanguagePreferenceStore

    init(store: any LanguagePreferenceStore = UserDefaultsLanguagePreferenceStore()) {
        self.store = store
        self.selection = store.selection()
    }

    /// The language actually being rendered, with `.system` already resolved against the
    /// device's preference order.
    var language: AppLanguage { selection.resolved() }

    /// What to put in the environment. Every `Text`, date and number in the app resolves
    /// against this.
    ///
    /// The device's own locale with its language subtag swapped, rather than
    /// `AppLanguage.locale`. That one is region-less by design — `Locale("uk")` — and a
    /// region-less Ukrainian locale does not mean "Ukrainian words, everything else as the
    /// reader has it": it means Ukraine's conventions, so a reader in the United States who
    /// only wanted the words to change would also get Monday-first weeks, a 24-hour clock
    /// and a comma for the decimal point. Keeping the region and moving only the language
    /// is what that property's own comment describes.
    var locale: Locale {
        var components = Locale.Components(locale: .current)
        components.languageComponents.languageCode = Locale.LanguageCode(language.languageCode)
        return Locale(components: components)
    }

    /// `Calendar.current`, speaking the app's language.
    ///
    /// Needed because `Calendar` carries a locale of its own, and that locale — not the
    /// SwiftUI environment — is what supplies `standaloneMonthSymbols`, the weekday symbols
    /// and `firstWeekday`. `Calendar.current` takes the *device's*, so without this the
    /// History grid keeps the month name and the day letters of the language the app
    /// launched in, beside a screen that has already repainted in the chosen one.
    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = locale
        return calendar
    }

    func select(_ selection: LanguageSelection) {
        guard selection != self.selection else { return }
        self.selection = selection
        store.setSelection(selection)
    }
}

extension AppLanguage {

    /// The language's name in itself — "English", "Українська".
    ///
    /// Deliberately not translated. A language list that renames itself when the app
    /// language changes is unusable for the one person it exists for: someone who cannot
    /// read the current language and is looking for their own.
    ///
    /// Built from `Locale` rather than written out, so a third language cannot ship with
    /// its name missing, and capitalised for the locale itself — `Locale` returns
    /// "українська" lower-cased, which is correct Ukrainian orthography in a sentence but
    /// not for a list entry.
    var endonym: String {
        let locale = self.locale
        let name = locale.localizedString(forLanguageCode: languageCode) ?? languageCode
        return name.capitalized(with: locale)
    }
}
