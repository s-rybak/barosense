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
    case tagVocabulary
    case healthLog
    case pressureLog
}

/// Removes every personal and health record Barosense holds.
///
/// Deliberately a separate type rather than a method on any one store: the data is spread
/// across three SwiftData containers that know nothing about each other, and "erase
/// everything" is a promise about all of them at once. One place to walk them is also one
/// place to keep in step when a fourth lands.
///
/// **Not transactional, and cannot be.** Three containers means three saves; a crash
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
    private let tagStore: any WellbeingTagStore
    private let healthLog: any HealthSampleStore
    private let pressureLog: any PressureSampleStore

    init(profileStore: any UserProfileStore,
         tagStore: any WellbeingTagStore,
         healthLog: any HealthSampleStore,
         pressureLog: any PressureSampleStore) {
        self.profileStore = profileStore
        self.tagStore = tagStore
        self.healthLog = healthLog
        self.pressureLog = pressureLog
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
