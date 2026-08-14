import Foundation

/// The words on a notification.
///
/// ## The vocabulary rule applies here more than anywhere
///
/// A notification is the one surface that speaks to the user without being opened, and it is the
/// surface App Review reads first. Everything in
/// `.claude/skills/appstore_compliance/SKILL.md` holds: this asks the user a question and says
/// what answering it is for. It does not tell them how they feel, warn them about a symptom, or
/// imply the app knows what is coming. It also interpolates nothing — no intensity, no tag, no
/// count — because a notification body is shown on a locked screen, and health data belongs to
/// whoever is holding the phone rather than to whoever can see it.
///
/// ## Why the words are resolved by name and not by environment
///
/// The copy is built at the moment the notification is handed to the system, which may be days
/// before it fires, and it is the app's *chosen* language that has to survive that — not the
/// device's, and not the one iOS will resolve at delivery time. `AppLanguage.shippedCopy` reads
/// the named language's `.lproj` for exactly this.
///
/// The keys below are the base-language text, which is also what the lookup falls back to. They
/// are carried in `Localizable.xcstrings` with `extractionState: manual`, because no
/// `LocalizedStringKey` literal in the source names them and nothing would otherwise extract
/// them. Editing one here without editing the catalogue ships the English text to a Ukrainian
/// reader.
enum NotificationCopy {

    /// One line, phrased as the question it is. Not "time to check in" — the point of the
    /// reminder is the answer, and the shortest way to ask for one is to ask.
    private static let checkInReminderTitle = "How are you feeling?"

    /// Says what it costs, which is the only argument the notification has. It makes no promise
    /// about what the entry will reveal.
    private static let checkInReminderBody = "A quick check-in takes a few seconds."

    static func title(for kind: NotificationKind, in language: AppLanguage) -> String {
        switch kind {
        case .checkInReminder: resolve(checkInReminderTitle, in: language)
        }
    }

    static func body(for kind: NotificationKind, in language: AppLanguage) -> String {
        switch kind {
        case .checkInReminder: resolve(checkInReminderBody, in: language)
        }
    }

    /// Falls back to the key, which is the base-language copy — the same fallback every other
    /// lookup in the app has, and the reason a missing translation ships readable English rather
    /// than an identifier.
    private static func resolve(_ key: String, in language: AppLanguage) -> String {
        language.shippedCopy(forKey: key) ?? key
    }
}
