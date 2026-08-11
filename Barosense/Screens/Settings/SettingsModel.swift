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

    /// Builds the eraser from the same store instances the screens read, so an erase
    /// cannot miss a store the settings screen is showing.
    init(profileStore: any UserProfileStore,
         tagStore: any WellbeingTagStore,
         healthLog: any HealthSampleStore,
         pressureLog: any PressureSampleStore,
         healthAccess: any HealthAccessReporting) {
        self.profileStore = profileStore
        self.tagStore = tagStore
        self.healthLog = healthLog
        self.healthAccess = healthAccess
        self.eraser = BarosenseDataEraser(profileStore: profileStore,
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
    /// Two facts, not one, because iOS answers only the first and the second is what the
    /// user actually cares about:
    ///
    /// - `access` — has the user been asked about every type Barosense reads. This is the
    ///   only authorisation fact iOS exposes for a read set, and it is what the switch
    ///   shows.
    /// - `hasReadings` — has anything actually landed in the training log recently. When
    ///   the answer is no and the user *has* been asked, the cause is either a refusal or
    ///   an empty Health store, and iOS will not say which. The caption states the
    ///   observable fact instead of guessing.
    struct HealthConnection: Equatable {
        var access: HealthAccessState = .unavailable
        var hasReadings = false

        var isConnected: Bool { access == .requested }
        var isInteractive: Bool { access != .unavailable }
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
        case presentedSheet
        /// Nothing to present — send the user to the Health app instead.
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
            await load()
            return .presentedSheet

        case .requested:
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
