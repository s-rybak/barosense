import SwiftUI

/// Composition root: opens the durable store, builds the stores on top of it, and decides
/// what the first screen is.
///
/// This is the one place that knows which `…Store` implementation is real. Everything
/// downstream takes the protocols, which is what keeps the flow testable and the SwiftData
/// dependency out of the views.
@MainActor
@Observable
final class AppServices {

    enum Phase {
        /// Opening the store. Brief, but not instantaneous on a cold launch, and showing
        /// onboarding before the profile has been read would restart a flow the user
        /// already finished.
        case opening
        /// The store could not be opened. There is no useful degraded mode: the app's
        /// whole job is accumulating history.
        case unavailable
        case onboarding
        case ready
    }

    private(set) var phase: Phase = .opening

    private(set) var profileStore: (any UserProfileStore)?
    private(set) var tagStore: (any WellbeingTagStore)?
    private(set) var checkInStore: (any CheckInStore)?

    /// Drives the check-in reminder. `nil` until `start()` has opened the store, which is also
    /// the only state in which there is nothing worth reminding anybody about.
    private(set) var reminders: CheckInReminderController?

    /// Everything the settings tab reads. `nil` until `start()` has opened the store —
    /// which is also the only state in which the tab is not on screen.
    private(set) var settings: SettingsDependencies?

    /// The sensor logs. Opened by `BarosenseApp` because the ingest controllers need them
    /// at launch, and handed here so an erase reaches them too — a "delete my data" that
    /// only knew about the profile store would leave the barometer history behind.
    private let healthLog: any HealthSampleStore
    private let pressureLog: any PressureSampleStore

    /// The epoch table, on the same container as the barometer log. Held for the reason the
    /// two logs are: an erase has to reach it.
    private let locationEpochs: any PressureLocationEpochStore

    /// The forecast archive. Held for the reason the sensor logs are: an erase has to reach it.
    private let weatherArchive: any WeatherForecastStore

    /// The same Health reporter Settings later reads. Exposed so onboarding can raise that
    /// sheet through this instance rather than a second one that would disagree about state.
    let healthAccess: any HealthAccessReporting

    init(healthLog: any HealthSampleStore,
         pressureLog: any PressureSampleStore,
         locationEpochs: any PressureLocationEpochStore,
         weatherArchive: any WeatherForecastStore,
         healthAccess: any HealthAccessReporting = HealthKitAccessReporter()) {
        self.healthLog = healthLog
        self.pressureLog = pressureLog
        self.locationEpochs = locationEpochs
        self.weatherArchive = weatherArchive
        self.healthAccess = healthAccess
    }

    /// Opens the store, seeds the tag vocabulary, and reports whether onboarding still
    /// has to run. Safe to call again after a failure.
    func start() async {
        switch phase {
        case .opening, .unavailable: break
        case .onboarding, .ready: return
        }

        phase = .opening

        do {
            let container = try BarosenseModelContainer.makeDurable()
            let profileStore = SwiftDataUserProfileStore(modelContainer: container)
            let tagStore = SwiftDataWellbeingTagStore(modelContainer: container)
            // Same container as the tag vocabulary a check-in points at, so the two cannot
            // be opened separately and disagree about which tags exist.
            let checkInStore = SwiftDataCheckInStore(modelContainer: container)
            // Same container again, for the reason the check-ins are on it: the reminder is
            // planned off the check-in table, and two containers could be opened separately
            // and disagree about which rows exist.
            let notificationLog = SwiftDataNotificationStore(modelContainer: container)
            // One preference and one deliverer, shared by the controller that plans reminders
            // and the settings switch that governs it. Two instances would agree here anyway —
            // both read the same `UserDefaults` and the same notification centre — but this is
            // the file that decides which implementation is real, and a shared instance is what
            // makes that decision visible in one place instead of twice by coincidence.
            let reminderPreferences = UserDefaultsReminderPreferenceStore()
            let notifications = UserNotificationCenterDeliverer()

            // Seeding runs at every launch by contract — `insertIfAbsent` leaves renamed
            // and archived rows alone, and writes nothing when there is nothing new.
            try await tagStore.insertIfAbsent(WellbeingTag.seeds)

            let profile = try await profileStore.profile()

            self.profileStore = profileStore
            self.tagStore = tagStore
            self.checkInStore = checkInStore
            self.reminders = CheckInReminderController(checkIns: checkInStore,
                                                       store: notificationLog,
                                                       deliverer: notifications,
                                                       preferences: reminderPreferences)
            self.settings = SettingsDependencies(profileStore: profileStore,
                                                 tagStore: tagStore,
                                                 checkInStore: checkInStore,
                                                 healthLog: healthLog,
                                                 pressureLog: pressureLog,
                                                 locationEpochs: locationEpochs,
                                                 weatherArchive: weatherArchive,
                                                 notificationLog: notificationLog,
                                                 notifications: notifications,
                                                 reminderPreferences: reminderPreferences,
                                                 healthAccess: healthAccess,
                                                 locationAccess: CoreLocationAccessReporter())
            phase = profile?.hasCompletedOnboarding == true ? .ready : .onboarding
        } catch {
            phase = .unavailable
        }
    }

    func onboardingFinished() {
        phase = .ready
    }

    /// Puts the user back at the start after "delete my data".
    ///
    /// Re-seeds first. The erase removed the vocabulary along with everything else, and
    /// the tag step is the one answer onboarding insists on — dropping into a flow with
    /// nothing to choose would strand them on step two.
    func restartOnboarding() async {
        if let tagStore {
            try? await tagStore.insertIfAbsent(WellbeingTag.seeds)
        }
        phase = .onboarding
    }
}

/// Chooses between onboarding and the app proper.
struct AppRootView: View {

    let ingest: HealthIngestController
    let pressure: PressureCollectionController

    /// Refreshes the WeatherKit archive on activation. Built at the composition root because
    /// it shares the barometer's background task and must exist before the first one fires.
    let weather: WeatherForecastController

    /// The forward half of the chart. Built at the composition root and passed through rather
    /// than rebuilt here, so the chart and `weather`'s feature row share one cached offset.
    let forecast: PressureForecastReader

    /// Threaded through rather than built here: it has to outlive this view and exist before it,
    /// because a tap can be delivered while the window is still being built.
    let router: NotificationRouter

    @State private var services: AppServices
    @State private var languages = LanguageController()

    init(ingest: HealthIngestController,
         pressure: PressureCollectionController,
         weather: WeatherForecastController,
         forecast: PressureForecastReader,
         healthLog: any HealthSampleStore,
         pressureLog: any PressureSampleStore,
         locationEpochs: any PressureLocationEpochStore,
         weatherArchive: any WeatherForecastStore,
         router: NotificationRouter) {
        self.ingest = ingest
        self.pressure = pressure
        self.weather = weather
        self.forecast = forecast
        self.router = router
        _services = State(initialValue: AppServices(healthLog: healthLog,
                                                    pressureLog: pressureLog,
                                                    locationEpochs: locationEpochs,
                                                    weatherArchive: weatherArchive))
    }

    var body: some View {
        Group {
            switch services.phase {
            case .opening:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.surface.ignoresSafeArea())

            case .unavailable:
                StoreUnavailableView { Task { await services.start() } }

            case .onboarding:
                if let profileStore = services.profileStore, let tagStore = services.tagStore {
                    OnboardingFlow(profileStore: profileStore,
                                   tagStore: tagStore,
                                   // Both system prompts are raised from the flow's Apple
                                   // Health step and nowhere earlier. It asks through the
                                   // barometer controller the rest of the app samples with,
                                   // so the reading that answer produces is the log's first
                                   // row rather than a duplicate taken beside it.
                                   sensorAccess: DeviceSensorAccess(health: services.healthAccess,
                                                                    pressure: pressure),
                                   onFinished: services.onboardingFinished)
                }

            case .ready:
                // Both stores are non-nil whenever the phase is `.ready` — `start()` sets
                // them in the same `do` block that sets the phase. Unwrapped rather than
                // force-unwrapped anyway: a `!` here would turn a future reordering of that
                // block into a launch crash instead of a blank frame.
                if let checkInStore = services.checkInStore, let tagStore = services.tagStore {
                    RootView(ingest: ingest,
                             pressure: pressure,
                             weather: weather,
                             forecast: forecast,
                             checkInStore: checkInStore,
                             tagStore: tagStore,
                             reminders: services.reminders,
                             settings: services.settings,
                             languages: languages,
                             router: router,
                             onDataErased: { await services.restartOnboarding() })
                }
            }
        }
        // The language row in Settings takes effect here and nowhere else: SwiftUI resolves
        // every `LocalizedStringKey` in the tree against this locale, so a change repaints
        // the whole app in the new language without a relaunch. iOS's own idea of the app
        // language moves separately, at the next launch — see
        // `UserDefaultsLanguagePreferenceStore`.
        //
        // The calendar goes in beside it because a locale alone does not carry month names,
        // weekday letters or the first day of the week — a `Calendar` does, out of its own
        // `locale`, and `Calendar.current` takes the device's. Views that format a date read
        // both back out of the environment rather than reaching for `.current`.
        .environment(\.locale, languages.locale)
        .environment(\.calendar, languages.calendar)
        .task { await services.start() }
        // Ingest follows the phase rather than being started once at launch. Keyed on the
        // Bool and not on the phase itself so the two onboarding-side phases do not retrigger
        // it, and so the transition that matters — onboarding ending, or "delete my data"
        // sending the user back to it — is the only thing that moves the gate.
        .task(id: isIngestAllowed) { await ingest.setEnabled(isIngestAllowed) }
    }

    /// Whether the Health log may take new readings.
    ///
    /// Off through onboarding. On a fresh install that is simply "nothing has been asked
    /// yet"; after "delete my data" it is what keeps the erase true — the observers stay
    /// registered and would otherwise refill the log with the same week of readings within
    /// minutes. See `HealthIngestGate`.
    private var isIngestAllowed: Bool {
        if case .ready = services.phase { return true }
        return false
    }
}

/// Shown when the on-disk store will not open. Offers a retry and nothing else — there is
/// no version of this app that is useful without somewhere to put the history.
private struct StoreUnavailableView: View {

    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Barosense can't open its data")
                .font(Typography.onboardingTitleCompact)
                .foregroundStyle(Palette.heading)
                .multilineTextAlignment(.center)

            Text("Restart the app. If this keeps happening, free up some space on your device.")
                .font(Typography.onboardingBodySmall)
                .foregroundStyle(Palette.bodyText)
                .multilineTextAlignment(.center)

            Button(action: retry) {
                Text("Try again")
                    .font(Typography.primaryAction)
                    .foregroundStyle(Palette.onInk)
                    .padding(.horizontal, 28)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Palette.ink)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.ignoresSafeArea())
    }
}

#Preview("Store unavailable") {
    StoreUnavailableView {}
}
