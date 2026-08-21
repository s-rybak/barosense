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

    /// Read for the location authorisation state, and — from `.notRequested` only — to raise
    /// the system prompt behind the explanatory screen. Never used to take a fix: that is
    /// `LocationEpochRecorder`'s job, on a foreground activation.
    let locationAccess: any LocationAccessReporting

    /// The notification log, read for the day's count. The row states what the app has already
    /// committed to today, and the only place that is recorded is the log — the system's
    /// notification centre cannot be asked what it delivered yesterday, which is the whole
    /// reason the log exists. See `NotificationBudget`.
    let notificationLog: any NotificationStore

    /// Read for the authorisation state and, when the switch is tapped from off, to ask for it.
    /// Never used to schedule anything: `NotificationDispatcher` is the only path to the system.
    let notifications: any NotificationDelivering

    let reminderPreferences: any ReminderPreferenceStore

    let eraser: BarosenseDataEraser

    /// The epoch table. Read for the place name the location row prints, and erased with
    /// everything else — a city, an oblast and a country per place the user has been is the
    /// nearest thing in this app to a movement record.
    let locationEpochs: any PressureLocationEpochStore

    /// The forecast archive. Read for nothing on this screen except the erase — the switch
    /// below reports a preference, not a row count — and erased with everything else, because
    /// an hour-by-hour record of where the user was is exactly what the promise covers.
    let weatherArchive: any WeatherForecastStore

    /// The WeatherKit switch's own storage. Shared with the refresher, so the screen and the
    /// pass cannot disagree about whether the feature is on.
    let weatherPreferences: any WeatherKitPreferenceStore

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
         locationEpochs: any PressureLocationEpochStore,
         weatherArchive: any WeatherForecastStore,
         notificationLog: any NotificationStore,
         notifications: any NotificationDelivering = UserNotificationCenterDeliverer(),
         reminderPreferences: any ReminderPreferenceStore = UserDefaultsReminderPreferenceStore(),
         weatherPreferences: any WeatherKitPreferenceStore = UserDefaultsWeatherKitPreferenceStore(),
         healthAccess: any HealthAccessReporting,
         // No default. A `CoreLocationAccessReporter()` here would make every test that builds
         // this struct touch `CLLocationManager` by omission, which is the opposite of the rule
         // that keeps the domain layer runnable without a device.
         locationAccess: any LocationAccessReporting) {
        self.profileStore = profileStore
        self.tagStore = tagStore
        self.checkInStore = checkInStore
        self.healthLog = healthLog
        self.pressureLog = pressureLog
        self.locationEpochs = locationEpochs
        self.weatherArchive = weatherArchive
        self.weatherPreferences = weatherPreferences
        self.healthAccess = healthAccess
        self.locationAccess = locationAccess
        self.notificationLog = notificationLog
        self.notifications = notifications
        self.reminderPreferences = reminderPreferences
        self.eraser = BarosenseDataEraser(profileStore: profileStore,
                                          checkInStore: checkInStore,
                                          tagStore: tagStore,
                                          healthLog: healthLog,
                                          pressureLog: pressureLog,
                                          locationEpochs: locationEpochs,
                                          weatherArchive: weatherArchive,
                                          notificationLog: notificationLog)
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
                             locationEpochs: InMemoryPressureLocationEpochStore(),
                             weatherArchive: InMemoryWeatherForecastStore(),
                             notificationLog: InMemoryNotificationStore(),
                             // Reports itself unauthorised, so a preview cannot put a system
                             // permission prompt on screen from a canvas refresh.
                             notifications: NoOpNotificationDeliverer(),
                             reminderPreferences: InMemoryReminderPreferenceStore(),
                             weatherPreferences: InMemoryWeatherKitPreferenceStore(),
                             healthAccess: UnavailableHealthAccessReporter(),
                             // Reports `.notRequested`, which renders the location row in its
                             // one actionable state — and asks CoreLocation for nothing, so a
                             // canvas refresh cannot put a real system prompt on screen. Same
                             // contract as `NoOpNotificationDeliverer` above.
                             locationAccess: NoOpLocationAccessReporter())
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
    ///   what the switch shows, and it is off unless every type a working device would
    ///   have produced came back with data (`HealthAccessState.isFullyReadable`).
    /// - `hasReadings` — has anything landed in the *training log* in the last week. Read
    ///   access can be granted while ingestion has stalled or the user has stopped wearing
    ///   the watch, and that is worth saying without turning the switch off.
    struct HealthConnection: Equatable {
        var access: HealthAccessState = .unavailable
        var hasReadings = false

        /// On only when every type a working device would have produced is proven readable,
        /// and at least one of them is. Never "the user has been asked" — being asked says
        /// nothing about the answer. Blood oxygen is deliberately not part of the test; see
        /// `HealthAccessState.isFullyReadable`.
        var isConnected: Bool { access.isFullyReadable }

        var isInteractive: Bool { access != .unavailable }

        /// What came back empty, for the caption. Wider than what the switch tests on —
        /// blood oxygen can appear here with the switch on. Empty while the sheet has not
        /// been answered.
        var unreadableTypes: [HealthMetricKind] { access.unreadableTypes }

        /// Nothing in the read set came back at all. What a refused sheet leaves behind —
        /// and, indistinguishably, what an empty Health store looks like, which is why the
        /// caption it drives describes the reading rather than asserting a refusal.
        var hasNothingReadable: Bool {
            unreadableTypes.count == HealthMetricKind.allCases.count
        }
    }

    /// How the location row should read.
    ///
    /// Simpler than `HealthConnection`, because CoreLocation answers the question HealthKit
    /// refuses to: there is no probe read here and no "proven grant / unproven refusal"
    /// asymmetry, just the authorisation the system reports and the place it produced.
    struct LocationConnection: Equatable {

        var access: LocationAccessState = .unavailable

        /// What the current epoch calls itself. `nil` before the first fix, and on a device
        /// where the geocoder has never answered — both ordinary, and the row then states the
        /// permission without naming a place.
        var place: PlaceName?

        /// **Reduced accuracy counts as on.** The epochs round every coordinate to 0.1°
        /// (~11 km) and WeatherKit's grid is coarser again, so precise location has no
        /// consumer in this app. A row that showed `.reduced` as a problem would be pushing
        /// the user to hand over precision nothing here reads, which is the surgical-
        /// permissions rule broken on CoreLocation instead of HealthKit.
        var isConnected: Bool { access.isGranted }

        var isInteractive: Bool { access.isInteractive }

        /// Granted, at the accuracy the app actually asks for. Not a defect, and the row has a
        /// test pinning that — it is the most likely thing to regress the next time this
        /// screen is edited.
        var isReducedAccuracy: Bool { access == .granted(accuracy: .reduced) }

        /// The user still has an answer to give, so the app may explain itself and then ask.
        var canExplainBeforeAsking: Bool { access.canPresentPrompt }

        /// Nothing left to ask: iOS will not present the prompt twice. Only Settings.app can
        /// change this now — which is also true of a *granted* row somebody wants to revoke.
        var needsSystemSettings: Bool { access.needsSystemSettings }
    }

    /// How the check-in reminder row should read.
    ///
    /// Two facts again, and for the same reason as `HealthConnection`: what the user asked for
    /// and what iOS will actually deliver are different questions that can disagree. A switch
    /// showing the preference alone would sit there reading "on" for someone who tapped
    /// "Don't Allow" months ago and has been getting nothing since.
    struct ReminderSettings: Equatable {

        /// The user's own choice, from `ReminderPreferenceStore`. On for an install that has
        /// never touched the switch.
        var isPreferred = true

        /// Whether iOS will deliver a notification at all.
        var isAuthorized = false

        /// Rows already counted against today's allowance — scheduled as well as delivered.
        /// A reminder placed for this evening is spent from the moment it is written; see
        /// `NotificationDeliveryState.spendsAllowance`.
        var countedToday = 0

        var dailyLimit = NotificationBudget.dailySendLimit

        /// On only when the user wants it *and* iOS will deliver it.
        var isOn: Bool { isPreferred && isAuthorized }

        /// Wanted, but not being delivered. The one state the switch cannot settle on its own —
        /// only iOS Settings can.
        var isBlockedBySystem: Bool { isPreferred && !isAuthorized }
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
    private(set) var location = LocationConnection()

    /// The WeatherKit switch. A plain preference — unlike Health, Location and notifications,
    /// nothing outside the app can change it, so there is no second fact to reconcile and no
    /// state where the switch means something other than what the user last chose.
    private(set) var isWeatherKitEnabled = true

    /// What the switch shows while a tap is still being carried out. Same purpose as
    /// `pendingReminderValue`: the preference is written and the row re-read, and a switch
    /// reading only the stored value springs back for the length of that.
    private(set) var pendingWeatherKitValue: Bool?

    /// What the WeatherKit switch should display.
    var isWeatherKitOn: Bool { pendingWeatherKitValue ?? isWeatherKitEnabled }
    private(set) var reminders = ReminderSettings()
    private(set) var eraseState: EraseState = .idle

    /// What the switch shows while a tap is still being carried out, if anything.
    ///
    /// A tap is not answered on the spot: the preference is written, a reconcile pass re-plans a
    /// week against it, and only then is the row re-read. For that stretch `reminders` still
    /// describes the state before the tap, so a switch reading it alone springs back to where it
    /// was and moves again a moment later — which reads as a control that did not take the tap.
    ///
    /// Set only where the user's choice is the thing that decides the outcome. When iOS has the
    /// last word — permission not granted — there is nothing to be optimistic about, and the
    /// switch stays where it is until the system has answered.
    private(set) var pendingReminderValue: Bool?

    /// What the reminder switch should display.
    var isReminderOn: Bool { pendingReminderValue ?? reminders.isOn }

    /// Raised while the erase confirmation is on screen. Erasing is irreversible and
    /// reaches every store at once, so it never runs straight off a tap.
    var isConfirmingErase = false

    /// Raised while the location explanation is on screen, before anything reaches iOS.
    ///
    /// The same shape as `CheckInReminderPrimer` and for the same reason: iOS grants one
    /// prompt per install, and one answered without context is answered "no".
    var isExplainingLocation = false

    /// Raised when the user asks to reset what the model has learned. There is no learned
    /// model yet, so this explains rather than pretends.
    var isShowingLearnedDataNotice = false

    private let dependencies: SettingsDependencies
    private let now: @Sendable () -> Date

    /// The app's calendar, not the device's, for the same reason every date on screen uses it:
    /// "today" here is the boundary `NotificationBudget` counts the day's allowance against, and
    /// the row has to agree with the cap the dispatcher enforced. See `LanguageController`.
    private let calendar: Calendar

    /// Called after a successful erase so the app can hand the user back to onboarding.
    private let onDataErased: () async -> Void

    /// Called after the reminder preference changes, to re-plan against it.
    ///
    /// The switch is not finished when the preference is written: a week of reminders is already
    /// sitting in the system's notification centre, and only a reconcile pass withdraws them —
    /// see `CheckInReminderController.refresh`. Awaited rather than fired and forgotten, so the
    /// count this screen reloads afterwards is the count the pass left behind.
    private let onRemindersChanged: () async -> Void

    init(dependencies: SettingsDependencies,
         calendar: Calendar = .current,
         now: @escaping @Sendable () -> Date = { Date() },
         onDataErased: @escaping () async -> Void,
         onRemindersChanged: @escaping () async -> Void = {}) {
        self.dependencies = dependencies
        self.calendar = calendar
        self.now = now
        self.onDataErased = onDataErased
        self.onRemindersChanged = onRemindersChanged
    }

    // MARK: - Loading

    /// Re-reads everything the list shows. Safe to call on every appearance.
    func load() async {
        async let profile = loadProfile()
        async let access = dependencies.healthAccess.accessState()
        async let hasReadings = loadHasRecentReadings()
        async let reminders = loadReminders()
        async let location = loadLocation()

        self.profile = await profile
        health = HealthConnection(access: await access, hasReadings: await hasReadings)
        self.reminders = await reminders
        self.location = await location
        isWeatherKitEnabled = dependencies.weatherPreferences.isWeatherKitEnabled()
    }

    /// The location row: the authorisation, and the name of the place the forecast is for.
    ///
    /// The place comes from the epoch table rather than from a fresh reverse geocode. That is
    /// the whole point of the table — Apple's geocoder is throttled with unpublished limits,
    /// and a settings screen that geocoded on every appearance would be throttled into
    /// answering nothing.
    private func loadLocation() async -> LocationConnection {
        async let access = dependencies.locationAccess.accessState()
        let epoch = try? await dependencies.locationEpochs.currentEpoch()

        return LocationConnection(access: await access,
                                  place: epoch.map(\.place).flatMap { $0.isEmpty ? nil : $0 })
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

    /// The reminder row, read fresh: the preference is the app's, the authorisation is iOS's and
    /// can be revoked from another app, and the count moves every time a pass schedules anything.
    private func loadReminders() async -> ReminderSettings {
        let budget = NotificationBudget()
        // One reading of the clock for both the window and the count. Two would be the same
        // instant on all but one call in a million — the one that crosses midnight between
        // them, which fetches yesterday's rows and then counts them against today, and reports
        // an allowance the user has already spent as untouched.
        let instant = now()
        let today = budget.day(containing: instant, calendar: calendar)
        // Only today's rows are read. The log holds thirty days and none of the rest is on
        // screen, so a wider query would be paid for on every activation to display nothing.
        let records = (try? await dependencies.notificationLog.records(in: today)) ?? []

        return ReminderSettings(
            isPreferred: dependencies.reminderPreferences.isCheckInReminderEnabled(),
            isAuthorized: await dependencies.notifications.isAuthorized(),
            countedToday: budget.spentSends(on: instant, given: records, calendar: calendar),
            dailyLimit: budget.dailySendLimit
        )
    }

    // MARK: - Check-in reminder

    /// What tapping the reminder switch should do.
    enum ReminderToggleOutcome: Equatable {
        /// The preference flipped. The switch now reads what the user asked for.
        case changed
        /// Permission was granted, so the reminder is on. Whether the system prompt was actually
        /// shown is not knowable from here — iOS answers a repeat request from its own record.
        case authorized
        /// Nothing left to ask. Only iOS Settings can change this now.
        case needsSystemSettings
    }

    /// Runs whatever the current state allows, and leaves the displayed value to `load()`.
    ///
    /// The switch is deliberately not writable straight through. Off can mean two different
    /// things — the user turned it off, or iOS is refusing — and they need different actions,
    /// so the tap is interpreted here rather than in the binding.
    @discardableResult
    func toggleReminder() async -> ReminderToggleOutcome {
        // Delivering already: this is a plain preference and simply flips.
        if reminders.isAuthorized {
            await setReminderEnabled(!reminders.isPreferred)
            return .changed
        }

        // The switch reads off because iOS is not delivering, so whoever tapped it wants the
        // reminder on. The preference is written before asking: a granted prompt that left the
        // preference off would turn the switch straight back off and look like the tap failed.
        dependencies.reminderPreferences.setCheckInReminderEnabled(true)

        // Safe whether or not the prompt has been answered — the system answers a repeat from
        // its own record without showing anything, and a `false` from an answered refusal is
        // exactly what routes the user to Settings.
        let granted = await dependencies.notifications.requestAuthorization()
        await onRemindersChanged()
        await load()

        return granted ? .authorized : .needsSystemSettings
    }

    /// Records the choice and re-plans against it.
    ///
    /// The switch shows the new value for the whole of it — see `pendingReminderValue`. Cleared
    /// after `load()`, not before, so the displayed value passes straight from what the user
    /// asked for to what was stored without reading the old one in between.
    func setReminderEnabled(_ isEnabled: Bool) async {
        pendingReminderValue = isEnabled
        defer { pendingReminderValue = nil }

        dependencies.reminderPreferences.setCheckInReminderEnabled(isEnabled)
        await onRemindersChanged()
        await load()
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

    /// The current epoch's place, as one line, or `nil` when there is nothing to name.
    ///
    /// The formatting lives on `PlaceName` because the chart card prints the same sentence
    /// under the plot, and two copies of the de-duplication rule is how the two surfaces stop
    /// agreeing about what the place is called.
    var locationPlaceDescription: String? { location.place?.description }

    // MARK: - Location

    /// What tapping the location row should do.
    enum LocationToggleOutcome: Equatable {

        /// Never asked. The explanation goes up first; only its own button reaches iOS.
        case needsExplanation

        /// Asked and answered, either way. iOS will not present the prompt again, so the only
        /// remaining route — to revoke, to re-grant, or to change accuracy — is Settings.app.
        case needsSystemSettings

        /// Location services are off device-wide. The row is inert.
        case unavailable
    }

    /// Interprets a tap. Never writes the switch: like the Health and reminder rows, "off"
    /// means two different things and only the state can tell them apart.
    @discardableResult
    func toggleLocationAccess() async -> LocationToggleOutcome {
        // Re-read first. The grant can be changed in Settings while Barosense is backgrounded,
        // and sending someone to Settings to enable something they enabled ten seconds ago is
        // the same dead end this whole state machine exists to avoid.
        await load()

        if location.access == .unavailable { return .unavailable }
        if location.canExplainBeforeAsking { return .needsExplanation }
        return .needsSystemSettings
    }

    /// The user accepted the explanation. The one path from this screen to a system prompt.
    func requestLocationAccess() async {
        isExplainingLocation = false
        await dependencies.locationAccess.requestAccess()
        // The prompt's answer is not returned to us — CoreLocation reports it as a status
        // change — so the row settles on what is authorised *after* it rather than on the fact
        // it ran.
        await load()
    }

    /// "Not now". Nothing is written and nothing is asked: unlike the reminder, there is no
    /// preference to record here, and iOS still has the prompt in hand for the next tap.
    func declineLocationAccess() {
        isExplainingLocation = false
    }

    // MARK: - WeatherKit

    /// Records the choice. Nothing to interpret and nothing to ask the system — this switch is
    /// the app's own.
    ///
    /// Turning it off deliberately **does not** touch the archive. Rows already fetched stay,
    /// so switching back on resumes with the offset already calibrated rather than paying a
    /// cold start again (§5, PR 2, criterion 4). It also marks the feature as explained: a user
    /// who has found the switch has been told what it does by finding it.
    func setWeatherKitEnabled(_ isEnabled: Bool) {
        pendingWeatherKitValue = isEnabled
        defer { pendingWeatherKitValue = nil }

        dependencies.weatherPreferences.setHasOfferedWeatherKit(true)
        dependencies.weatherPreferences.setWeatherKitEnabled(isEnabled)
        isWeatherKitEnabled = isEnabled
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
