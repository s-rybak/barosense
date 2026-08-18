import Foundation

/// What "delete my data" could not remove.
enum DataEraseFailure: Error, Sendable {

    /// At least one store refused. `stores` names them so the message can say what is
    /// still on the device rather than "something went wrong".
    ///
    /// The underlying errors are deliberately not carried: they are SwiftData internals
    /// with nothing actionable in them, and the only useful next step for the user is to
    /// try again.
    case storesRefused(stores: [ErasableStore])
}

/// The stores an erase walks. A named enum rather than strings so a message about a
/// partial failure cannot go stale when a store is added.
enum ErasableStore: String, CaseIterable, Sendable {
    case profile
    case checkIns
    case tagVocabulary
    case healthLog
    case pressureLog
    case notificationLog
}

/// Removes every personal and health record Barosense holds.
///
/// Deliberately a separate type rather than a method on any one store: the data is spread
/// across three SwiftData containers that know nothing about each other, and "erase
/// everything" is a promise about all of them at once. One place to walk them is also one
/// place to keep in step when a fourth lands.
///
/// **Not transactional, and cannot be.** Three containers means separate saves; a crash
/// between them leaves the device part-erased. Every store is therefore attempted even
/// after one fails, and the failure names what survived — an erase that stopped at the
/// first error would leave the user believing more was removed than actually was.
///
/// What it does *not* touch, on purpose:
///
/// - `UserDefaults`. The only thing kept there is the language row
///   (`UserDefaultsLanguagePreferenceStore`), which holds nothing personal. Clearing it
///   would flip the app's language out from under someone mid-flow for no privacy gain.
/// - HealthKit itself. Those rows belong to the Health app, were only ever read, and are
///   not ours to delete. Revoking access is a separate action the user takes in Health.
struct BarosenseDataEraser: Sendable {

    private let profileStore: any UserProfileStore
    private let checkInStore: any CheckInStore
    private let tagStore: any WellbeingTagStore
    private let healthLog: any HealthSampleStore
    private let pressureLog: any PressureSampleStore
<<<<<<< HEAD
    private let notificationLog: any NotificationStore
=======
    private let notificationLog: any NotificationLogStore
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)

    init(profileStore: any UserProfileStore,
         checkInStore: any CheckInStore,
         tagStore: any WellbeingTagStore,
         healthLog: any HealthSampleStore,
         pressureLog: any PressureSampleStore,
<<<<<<< HEAD
         notificationLog: any NotificationStore) {
=======
         notificationLog: any NotificationLogStore) {
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)
        self.profileStore = profileStore
        self.checkInStore = checkInStore
        self.tagStore = tagStore
        self.healthLog = healthLog
        self.pressureLog = pressureLog
        self.notificationLog = notificationLog
    }

    /// Erases everything, then throws `DataEraseFailure.storesRefused` naming any store
    /// that would not empty.
    ///
    /// The sensor logs go first and the profile last. The profile is what the app reads to
    /// decide whether onboarding still has to run, so removing it is the step that hands
    /// the user back to a fresh install — doing it first would drop them into onboarding
    /// with the old history still on disk if a later step failed.
    func eraseEverything() async throws {
        var refused: [ErasableStore] = []

        // `.distantFuture` rather than `.now`: "before now" would leave behind a reading
        // taken in the same second, and on the pressure log that is not hypothetical —
        // a foreground activation records one on the way into Settings.
        await attempt(.pressureLog, into: &refused) {
            _ = try await pressureLog.deleteSamples(before: .distantFuture)
        }
        await attempt(.healthLog, into: &refused) {
            _ = try await healthLog.deleteSamples(before: .distantFuture)
        }
<<<<<<< HEAD
        // The notification log holds nothing health-derived (`NotificationRecord`), so this
        // step is a consistency obligation rather than a privacy one: it is what stops a
        // freshly erased install from starting with yesterday's daily allowance already
        // spent, and from holding scheduled rows for a history that no longer exists.
        //
        // It does not withdraw anything already handed to the system. That is
        // `NotificationDispatcher`'s job on the next activation, which finds no rows and
        // cancels what it does not recognise — an erase must not have to wake the
        // notification centre to finish.
=======
        // Before the check-ins it was planned from. The rows hold no health value, but they do
        // record when this person is at their phone and what the app decided to ask them —
        // which is the user's, and is covered by "delete my data" like everything else here.
        //
        // Requests iOS is already holding are **not** withdrawn here: this type walks stores
        // and nothing else, and a reminder living in the system centre is not a store. The
        // caller stands the plan down first — see `SettingsModel.eraseEverything`, which turns
        // the reminder off before it erases, so there is nothing left to arrive afterwards.
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)
        await attempt(.notificationLog, into: &refused) {
            try await notificationLog.deleteAllNotifications()
        }
        // Check-ins before the vocabulary they point at. The other order is the one that
        // can leave rows referencing tags that no longer exist: `deleteAllTags` is a hard
        // delete, so a check-in step refusing after it had run would orphan every user-made
        // tag reference. This way a refusal leaves a vocabulary with nothing pointing at
        // it, which is inert and which the next attempt clears.
        await attempt(.checkIns, into: &refused) {
            try await checkInStore.deleteAllCheckIns()
        }
        await attempt(.tagVocabulary, into: &refused) {
            try await tagStore.deleteAllTags()
        }
        await attempt(.profile, into: &refused) {
            try await profileStore.deleteProfile()
        }

        guard refused.isEmpty else {
            throw DataEraseFailure.storesRefused(stores: refused)
        }
    }

    private func attempt(_ store: ErasableStore,
                         into refused: inout [ErasableStore],
                         _ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            refused.append(store)
        }
    }
}
