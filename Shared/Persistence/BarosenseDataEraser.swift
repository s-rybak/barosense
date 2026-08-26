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
    case locationEpochs
    case weatherArchive
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
/// - The location *permission*. Revoking it is the user's action in Settings, the same way
///   revoking HealthKit access is theirs in Health. What the erase removes is every
///   coordinate and place name Barosense stored.
/// - HealthKit itself. Those rows belong to the Health app, were only ever read, and are
///   not ours to delete. Revoking access is a separate action the user takes in Health.
struct BarosenseDataEraser: Sendable {

    private let profileStore: any UserProfileStore
    private let checkInStore: any CheckInStore
    private let tagStore: any WellbeingTagStore
    private let healthLog: any HealthSampleStore
    private let pressureLog: any PressureSampleStore
    private let locationEpochs: any PressureLocationEpochStore
    private let weatherArchive: any WeatherForecastStore
    private let notificationLog: any NotificationStore

    /// The dismissed medication chips (`MedicationChipStore`). Not an `ErasableStore` case
    /// and not wrapped in `attempt`, because it has no failure mode to report: it is two
    /// `UserDefaults` keys, and `removeObject` cannot refuse. A case in that enum would put a
    /// store in the partial-failure message that can never appear in one.
    ///
    /// In the erase at all — unlike the language row or the WeatherKit switch — because what
    /// it holds is text the user typed, not a setting. Leaving it would also mis-fire later:
    /// the keys outlive the check-ins they were folded from, so a medication typed again after
    /// an erase would come back already suppressed.
    private let medicationChips: any MedicationChipStore

    init(profileStore: any UserProfileStore,
         checkInStore: any CheckInStore,
         tagStore: any WellbeingTagStore,
         healthLog: any HealthSampleStore,
         pressureLog: any PressureSampleStore,
         locationEpochs: any PressureLocationEpochStore,
         weatherArchive: any WeatherForecastStore,
         notificationLog: any NotificationStore,
         medicationChips: any MedicationChipStore = UserDefaultsMedicationChipStore()) {
        self.profileStore = profileStore
        self.checkInStore = checkInStore
        self.tagStore = tagStore
        self.healthLog = healthLog
        self.pressureLog = pressureLog
        self.locationEpochs = locationEpochs
        self.weatherArchive = weatherArchive
        self.notificationLog = notificationLog
        self.medicationChips = medicationChips
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

        // First, and outside the failure accounting. It cannot refuse, and doing it up front
        // means a run that later throws still leaves no dismissed chips pointing at check-ins
        // the same run removed.
        medicationChips.reset()

        // `.distantFuture` rather than `.now`: "before now" would leave behind a reading
        // taken in the same second, and on the pressure log that is not hypothetical —
        // a foreground activation records one on the way into Settings.
        await attempt(.pressureLog, into: &refused) {
            _ = try await pressureLog.deleteSamples(before: .distantFuture)
        }
        // After the readings that point at them, and for the reason check-ins go before the
        // tag vocabulary: an epoch removed first would leave rows referencing a place that no
        // longer exists if the sample step then refused. This way a refusal leaves epochs
        // nothing points at, which is inert and which the next attempt clears.
        //
        // These rows are the closest thing in the app to a movement record — a city, an
        // oblast and a country per place the user has been — so they are squarely inside the
        // promise the erase makes, not housekeeping alongside it.
        await attempt(.locationEpochs, into: &refused) {
            try await locationEpochs.deleteAllEpochs()
        }
        // Machine-produced weather rather than anything the user typed — but it is a record
        // of *where* they were, hour by hour, and it is keyed to the epochs above. Leaving it
        // behind would leave a week of coordinates on a device the user has just wiped.
        await attempt(.weatherArchive, into: &refused) {
            try await weatherArchive.deleteAllForecasts()
        }
        await attempt(.healthLog, into: &refused) {
            _ = try await healthLog.deleteSamples(before: .distantFuture)
        }
        // The notification log holds nothing health-derived (`NotificationRecord`), so this
        // step is a consistency obligation rather than a privacy one: it is what stops a
        // freshly erased install from starting with yesterday's daily allowance already
        // spent, and from holding scheduled rows for a history that no longer exists.
        //
        // It does not withdraw anything already handed to the system. That is
        // `NotificationDispatcher`'s job on the next activation, which finds no rows and
        // cancels what it does not recognise — an erase must not have to wake the
        // notification centre to finish.
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
