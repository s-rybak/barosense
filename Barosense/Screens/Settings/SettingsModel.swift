import Foundation
import SwiftUI

/// Everything the settings screens need from the composition root.
///
/// A struct rather than five initialiser parameters threaded through three views: the
/// settings tab is the only part of the app that touches all of these at once, and this
/// keeps `RootView` from acquiring five stored properties it does not read.
struct SettingsDependencies: Sendable {
    let profileStore: any UserProfileStore
    let tagStore: any WellbeingTagStore
    let healthLog: any HealthSampleStore
    let healthAccess: any HealthAccessReporting
    let eraser: BarosenseDataEraser

    /// Read by the report screen and by nothing else in this tab.
    ///
    /// Both were already required by the initialiser for the eraser's sake; they became stored
    /// properties when the report arrived, because that screen summarises the same window of
    /// check-ins and barometer readings the erase would remove.
    let checkInStore: any CheckInStore
    let pressureLog: any PressureSampleStore

    /// Builds the eraser from the same store instances the screens read, so an erase
    /// cannot miss a store the settings screen is showing.
    init(profileStore: any UserProfileStore,
         tagStore: any WellbeingTagStore,
         checkInStore: any CheckInStore,
         healthLog: any HealthSampleStore,
         pressureLog: any PressureSampleStore,
         healthAccess: any HealthAccessReporting) {
        self.profileStore = profileStore
        self.tagStore = tagStore
        self.checkInStore = checkInStore
        self.healthLog = healthLog
        self.pressureLog = pressureLog
        self.healthAccess = healthAccess
        self.eraser = BarosenseDataEraser(profileStore: profileStore,
                                          checkInStore: checkInStore,
                                          tagStore: tagStore,
                                          healthLog: healthLog,
                                          pressureLog: pressureLog)
    }
}

extension SettingsDependencies {

    /// In-memory stack for previews. Nothing here touches disk or HealthKit, so a preview
    /// cannot put a real Health sheet on screen or erase a real device's history.
    static var preview: SettingsDependencies {
        SettingsDependencies(profileStore: InMemoryUserProfileStore(),
                             tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                             checkInStore: InMemoryCheckInStore(),
                             healthLog: InMemoryHealthSampleStore(),
                             pressureLog: InMemoryPressureSampleStore(),
                             healthAccess: UnavailableHealthAccessReporter())
    }
}

/// Drives the settings list (Figma `7:1246`).
///
/// Everything on screen is read on appearance rather than held: the Apple Health state can
/// change in another app while Barosense is backgrounded, and the profile changes on the
/// edit screen this one pushes.
@MainActor
@Observable
final class SettingsModel {

    /// How the Apple Health row should read.
    ///
    /// Two facts, not one, because they answer different questions and can disagree:
    ///
    /// - `access` — what Barosense can demonstrably read from HealthKit right now. This is
    ///   what the switch shows, and it is off unless every type in the read set came back
    ///   with data.
    /// - `hasReadings` — has anything landed in the *training log* in the last week. Read
    ///   access can be granted while ingestion has stalled or the user has stopped wearing
    ///   the watch, and that is worth saying without turning the switch off.
    struct HealthConnection: Equatable {
        var access: HealthAccessState = .unavailable
        var hasReadings = false

        /// On only when every type Barosense reads is proven readable. Never "the user has
        /// been asked" — being asked says nothing about the answer.
        var isConnected: Bool { access.isFullyReadable }

        var isInteractive: Bool { access != .unavailable }

        /// What the switch is off because of, for the caption. Empty while the sheet has
        /// not been answered.
        var unreadableTypes: [HealthMetricKind] { access.unreadableTypes }

        /// Nothing in the read set came back at all. What a refused sheet leaves behind —
        /// and, indistinguishably, what an empty Health store looks like, which is why the
        /// caption it drives describes the reading rather than asserting a refusal.
        var hasNothingReadable: Bool {
            unreadableTypes.count == HealthMetricKind.allCases.count
        }
    }

    /// Progress of "delete my data", which is slow enough to need a spinner and
    /// consequential enough to need a result.
    enum EraseState: Equatable {
        case idle
        case erasing
        case failed(stores: [ErasableStore])
    }

    private(set) var profile: UserProfile?
    private(set) var health = HealthConnection()
    private(set) var eraseState: EraseState = .idle

    /// Raised while the erase confirmation is on screen. Erasing is irreversible and
    /// reaches every store at once, so it never runs straight off a tap.
    var isConfirmingErase = false

    /// Raised when the user asks to reset what the model has learned. There is no learned
    /// model yet, so this explains rather than pretends.
    var isShowingLearnedDataNotice = false

    private let dependencies: SettingsDependencies
    private let now: @Sendable () -> Date

    /// Called after a successful erase so the app can hand the user back to onboarding.
    private let onDataErased: () async -> Void

    init(dependencies: SettingsDependencies,
         now: @escaping @Sendable () -> Date = { Date() },
         onDataErased: @escaping () async -> Void) {
        self.dependencies = dependencies
        self.now = now
        self.onDataErased = onDataErased
    }

    // MARK: - Loading

    /// Re-reads everything the list shows. Safe to call on every appearance.
    func load() async {
        async let profile = loadProfile()
        async let access = dependencies.healthAccess.accessState()
        async let hasReadings = loadHasRecentReadings()

        self.profile = await profile
        health = HealthConnection(access: await access, hasReadings: await hasReadings)
    }

    private func loadProfile() async -> UserProfile? {
        // A profile that will not load leaves the card showing its empty state. There is
        // nothing the user can do about it from here, and blocking the whole settings
        // screen on it would also block the one action that might fix it.
        try? await dependencies.profileStore.profile()
    }

    /// Whether the training log holds anything from the last week.
    ///
    /// Read from the log rather than from HealthKit: the log *is* the record of what
    /// Barosense managed to read, so it answers the question directly and costs no
    /// HealthKit query on a screen the user may open often.
    private func loadHasRecentReadings() async -> Bool {
        let end = now()
        let range = end.addingTimeInterval(-HealthMetricsWindow.refreshLookback.seconds)..<end

        for kind in HealthMetricKind.allCases {
            let samples = (try? await dependencies.healthLog.samples(of: kind, in: range)) ?? []
            if !samples.isEmpty { return true }
        }
        return false
    }

    // MARK: - Apple Health

    /// What tapping the switch should do.
    ///
    /// The switch is not a preference the app owns, so it cannot simply be written to.
    /// From "never asked" there is a sheet to show; after that only the Health app can
    /// change anything, and iOS will not present the sheet a second time.
    enum HealthToggleOutcome: Equatable {
        /// The sheet was shown and the state re-read behind it. Whether anything became
        /// readable is in `health`, not here — the tap is finished either way.
        case presentedSheet
        /// The re-check found access that was not there before. Nothing further to do:
        /// the switch is now on.
        case connected
        /// Nothing left to present — send the user to the Health app instead.
        case needsHealthApp
        case unavailable
    }

    @discardableResult
    func toggleHealthAccess() async -> HealthToggleOutcome {
        switch health.access {
        case .unavailable:
            return .unavailable

        case .notRequested:
            // A failure here means the sheet never appeared; re-reading the state below
            // leaves the row exactly as it was, which is the honest result.
            try? await dependencies.healthAccess.requestAccess()
            // The whole point of the re-read: the sheet's answer is not returned to us, so
            // the switch settles on what is readable *after* it, not on the fact it ran.
            await load()
            // Deliberately not routed to the Health app on a refusal. The sheet has just
            // been answered; bouncing the user straight into another app is the re-prompt
            // loop `.claude/skills/healthkit_permissions/SKILL.md` rules out. The caption
            // explains, and a second tap takes them there.
            return .presentedSheet

        case .requested:
            let wasConnected = health.isConnected
            // Re-check before sending the user away: the grant may have been given in the
            // Health app since this screen last loaded, in which case there is nothing to
            // send them there for.
            await load()

            if !wasConnected && health.isConnected { return .connected }

            // Either the switch was on and the user wants it off, or it is still off and
            // the app has nothing left to ask. Both are the Health app's to settle.
            return .needsHealthApp
        }
    }

    // MARK: - Erasing

    func confirmEraseEverything() {
        isConfirmingErase = true
    }

    /// Removes every stored record and hands the user back to onboarding.
    ///
    /// The onboarding hand-back runs only on a clean erase. Dropping someone into a fresh
    /// flow while some of their history is still on disk would rebuild a profile next to
    /// records it does not describe.
    func eraseEverything() async {
        guard eraseState != .erasing else { return }

        eraseState = .erasing
        do {
            try await dependencies.eraser.eraseEverything()
            eraseState = .idle
            profile = nil
            await onDataErased()
        } catch DataEraseFailure.storesRefused(let stores) {
            eraseState = .failed(stores: stores)
        } catch {
            eraseState = .failed(stores: ErasableStore.allCases)
        }
    }

    func dismissEraseFailure() {
        eraseState = .idle
    }
}
