import SwiftUI

/// Root container: the selected destination with the custom tab bar pinned to the bottom.
struct RootView: View {

    let ingest: HealthIngestController
    let pressure: PressureCollectionController

    /// Refreshes the forecast archive on activation. Every gate — both switches, the location
    /// permission, the slot budget — is inside it, so calling this on every activation is
    /// cheap and usually silent.
    let weather: WeatherForecastController

    /// The forward half of the pressure chart. Built at the composition root and shared with
    /// `weather`, so the picture and the feature row read one curve and one cached offset.
    let forecast: PressureForecastReader

    /// The two-stage risk model. `nil` until the store is open, which is a state this view is
    /// never shown in; optional rather than force-unwrapped at the composition root.
    let risk: WellbeingRiskEngine?

    let checkInStore: any CheckInStore
    let tagStore: any WellbeingTagStore

    /// `nil` only while the store is still opening, which is a state this view is never
    /// shown in. Optional rather than force-unwrapped at the composition root.
    let reminders: CheckInReminderController?
    let settings: SettingsDependencies?
    let languages: LanguageController

    /// Where a tapped notification wants to go. Owned by `BarosenseApp`, because a tap can be
    /// delivered before this view exists.
    let router: NotificationRouter

    let onDataErased: () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .now
    @State private var isLoggingCheckIn = false

    /// Raised once per install, before anything asks iOS for permission to notify. See
    /// `CheckInReminderPrimer`.
    @State private var isShowingReminderPrimer = false

    /// Raised once per install, before anything reaches WeatherKit. See `WeatherKitPrimer`.
    ///
    /// Sequenced after the reminder primer rather than shown alongside it: two explanatory
    /// sheets competing for the same first launch would put one behind the other, and the one
    /// behind would be answered without being read.
    @State private var isShowingWeatherPrimer = false

    /// Bumped when a check-in is written, and handed to the chart as a reload trigger.
    ///
    /// A sheet does not rebuild what it covers, so without this the chart behind it keeps the
    /// markers it was built with and the new dot appears only after a tab change. Passed down
    /// rather than used to re-identify the destination: re-identifying also reloads the
    /// screen's own `@State`, which threw away the range the user had picked on the chart.
    @State private var checkInRevision = 0

    /// Raised while Settings has something pushed. The pushed screens draw their own
    /// navigation bar and, in the design, no tab bar under them.
    @State private var isSettingsDetailPresented = false

    var body: some View {
        ZStack {
            Palette.surface.ignoresSafeArea()

            destination
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isSettingsDetailPresented {
                BarosenseTabBar(selection: tabBarSelection)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSettingsDetailPresented)
        .onChange(of: selection) { _, tab in
            // Leaving Settings while a detail is pushed would otherwise strand the tab bar
            // hidden on a tab that has no way to bring it back.
            if tab != .settings { isSettingsDetailPresented = false }
        }
        // The check-in is a sheet over whatever the user was looking at, not a destination
        // of its own (Figma `7:330` — the frame is drawn with a sheet's grab handle and no
        // tab bar). The raised centre action opens it; dismissing returns them where they
        // were.
        .sheet(isPresented: $isLoggingCheckIn) {
            // Stamped from the same recorder the Now screen reads, so the three figures on
            // the check-in are the ones the user could have seen a tab away — and so one
            // read serves both the stamp and the training log.
            LogScreen(checkInStore: checkInStore,
                      tagStore: tagStore,
                      health: ingest.recorder) {
                isLoggingCheckIn = false
                checkInRevision += 1
                // The model was fitted on a history that no longer matches the store. Dropping
                // the cache costs one refit on the next chart load and keeps the percentage
                // from describing a day the user has already logged.
                if let risk { Task { await risk.invalidate() } }
                // Today's reminder is no longer wanted — the user has just done the thing it
                // would have asked for. The planner drops the slot and the dispatcher
                // withdraws the row it was scheduled under.
                refreshReminders()
                // Onto the chart the new dot is already on. The one place the app moves the
                // user itself, and it is the point of the whole flow.
                selection = .now
            }
        }
        // The first activation of this view, which `onChange` below cannot see: the scene was
        // already `.active` before the root existed, so nothing fires for it. That is the only
        // moment the barometer would otherwise be missed — `start()` skips the launch reading
        // until the sensor has been asked about, and a user who skipped onboarding's Health
        // step has not been, so without this their first pressure row waits for a backgrounding
        // that may not come for hours. Idempotent: the recorder's fifteen-minute floor decides
        // whether the sensor runs, and on the connected path onboarding has just sampled.
        .task { pressure.sceneDidBecomeActive() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                ingest.sceneDidBecomeActive()
                // The phone is the barometer now, and foreground activation is where most
                // of the log actually comes from — background wakes are granted sparsely.
                // Cheap to call on every activation: the recorder's fifteen-minute floor
                // decides whether the sensor runs at all.
                pressure.sceneDidBecomeActive()
                // Nothing new is woken for this — it rides the activation the user initiated
                // and the barometer's existing background task. A pass with no slot due makes
                // no network call at all.
                weather.sceneDidBecomeActive()
                // Nothing wakes the app for this — the system holds the scheduled
                // notifications and fires them on its own. Activation is simply where the
                // next week's worth is brought back in step, and on a day when nothing has
                // changed the pass makes no cross-process calls at all.
                refreshReminders()
            }
        }
        // A reminder already handed to the system carries the words it was rendered with, and
        // iOS does not re-resolve them when the app's language changes. Everything on screen
        // repaints through the environment; the next week of notifications only does if
        // something withdraws and reissues them, which is what this pass does.
        .onChange(of: languages.language) { _, _ in
            refreshReminders()
        }
        // The reminder is explained here rather than at the end of onboarding: this is the
        // first moment the app has anything to remind anybody about, and a permission screen
        // between "finish setup" and seeing the app is one more thing to get past.
        .sheet(isPresented: $isShowingReminderPrimer) {
            CheckInReminderPrimer(onAccept: acceptReminderPrimer,
                                  onDecline: declineReminderPrimer)
        }
        .sheet(isPresented: $isShowingWeatherPrimer) {
            WeatherKitPrimer(onAccept: { setWeatherKitEnabled(true) },
                             onDecline: { setWeatherKitEnabled(false) })
        }
        .task {
            if let reminders, await reminders.shouldOfferPrimer() {
                isShowingReminderPrimer = true
                return
            }

            // Only once the notification question is settled. The two are independent, and the
            // one the user is not looking at can wait for the next launch.
            if settings?.weatherPreferences.hasOfferedWeatherKit() == false {
                isShowingWeatherPrimer = true
            }
        }
        // A tapped notification, which may have arrived before this view existed — see
        // `NotificationRouter`. Read on appearance as well as on change, because a tap that
        // launched the app is recorded while the window is still being built.
        .onChange(of: router.pending, initial: true) { _, route in
            guard route == .checkIn else { return }

            router.clear()
            // The reminder asked the user to check in. Opening the app on the tab they last
            // used and leaving them to find the button is the version of this that wastes the
            // notification.
            isLoggingCheckIn = true
        }
        // Follow the system appearance; introduce a dark palette when the design system defines one.
    }

    /// Records the answer to the WeatherKit explanation, whichever way it went.
    ///
    /// Both answers set "has been offered", which is what stops the screen reappearing and —
    /// more importantly — what unblocks `WeatherForecastRefresher`: it refuses to ask WeatherKit
    /// anything until the trade has been put in front of the user once.
    private func setWeatherKitEnabled(_ isEnabled: Bool) {
        isShowingWeatherPrimer = false

        guard let preferences = settings?.weatherPreferences else { return }
        preferences.setHasOfferedWeatherKit(true)
        preferences.setWeatherKitEnabled(isEnabled)

        // A yes should show up as a curve on the chart on this launch, not the next one.
        if isEnabled { Task { await weather.refresh() } }
    }

    /// The remaining destinations are still placeholders. As a real screen lands, add its
    /// case here and route to it.
    @ViewBuilder
    private var destination: some View {
        switch selection {
        // `.log` never lands here: `tabBarSelection` turns it into a sheet instead of
        // writing it. Folded in with `.now` rather than given a `default`, so a genuinely
        // new tab still has to be routed deliberately.
        case .now, .log:
            NowScreen(recorder: ingest.recorder,
                      pressure: pressure,
                      checkIns: checkInStore,
                      forecast: forecast,
                      risk: risk,
                      checkInRevision: checkInRevision)
        case .history:
            // The calendar is handed over rather than read from the environment: this
            // screen's model is built in `init`, before an environment exists, and the
            // calendar is what names its months and its weekday column.
            //
            // Re-identified on `checkInRevision` so a check-in written from the sheet appears
            // in the grid. Unlike the chart, this screen has no state worth preserving across
            // that — the month and period reset to today, which is where a user who has just
            // logged something is looking anyway. The language is in the identity for the
            // same reason: switching it has to rebuild the model around the new calendar,
            // or the grid keeps last month's name in the old language.
            HistoryScreen(checkInStore: checkInStore,
                          tagStore: tagStore,
                          calendar: languages.calendar)
                .id("\(checkInRevision)-\(languages.language.rawValue)")
        case .settings:
            if let settings {
                SettingsScreen(dependencies: settings,
                               languages: languages,
                               isDetailPresented: $isSettingsDetailPresented,
                               onDataErased: onDataErased,
                               onRemindersChanged: reconcileReminders)
            }
        case .insights:
            PlaceholderScreen(tab: selection)
        }
    }

    /// Re-plans the check-in reminder against the app's own language and calendar.
    ///
    /// Both are passed rather than left to `Locale.current`, for the reason every date on screen
    /// is: a reminder scheduled today fires days from now, and it has to speak the language the
    /// user picked in Settings — see `LanguageController`.
    private func refreshReminders() {
        Task { await reconcileReminders() }
    }

    /// The awaitable form, for the one caller that has to know when the pass has finished: the
    /// reminder switch in Settings reloads its count afterwards, and a fire-and-forget pass
    /// would leave it reading the number from before the switch was touched.
    private func reconcileReminders() async {
        guard let reminders else { return }

        await reminders.refresh(language: languages.language, calendar: languages.calendar)
    }

    /// The primer's "turn these on". Raises the system prompt and, if it is granted, plans the
    /// first week straight away rather than at the next launch.
    private func acceptReminderPrimer() {
        isShowingReminderPrimer = false

        Task {
            guard let reminders else { return }

            await reminders.acceptPrimer(language: languages.language,
                                         calendar: languages.calendar)
        }
    }

    private func declineReminderPrimer() {
        isShowingReminderPrimer = false
        reminders?.declinePrimer()
    }

    /// The bar's binding, with the raised centre action intercepted.
    ///
    /// Done here rather than in `BarosenseTabBar`: the bar's job is to report which item was
    /// tapped, and what a tap *means* is the root's decision. It also keeps the bar's
    /// selected-state highlight on the destination the user came from, which is what the
    /// frame shows while the sheet is up.
    private var tabBarSelection: Binding<AppTab> {
        Binding {
            selection
        } set: { tapped in
            if tapped == .log {
                isLoggingCheckIn = true
            } else {
                selection = tapped
            }
        }
    }
}

/// One reader for the preview, shared by the two arguments that take it — the same single
/// instance the app builds, so the canvas exercises the shipped shape rather than a variant.
private let previewForecast = PressureForecastReader(
    archive: InMemoryWeatherForecastStore(),
    samples: InMemoryPressureSampleStore(),
    epochs: InMemoryPressureLocationEpochStore(),
    preferences: InMemoryWeatherKitPreferenceStore()
)

#Preview {
    RootView(ingest: HealthIngestController(
        recorder: HealthSampleRecorder(reader: HealthKitDataReader(),
                                       log: InMemoryHealthSampleStore()),
        changeObserver: NoOpHealthChangeObserver()),
             pressure: PressureCollectionController(
                recorder: PressureSampleRecorder(source: UnavailablePressureSource(),
                                                 log: InMemoryPressureSampleStore()),
                display: NoOpPressureDisplayLink()),
             // No network in a preview: the provider throws and the reporter says the device
             // has no location, so a canvas refresh cannot reach WeatherKit or CoreLocation.
             weather: WeatherForecastController(
                refresher: WeatherForecastRefresher(
                    provider: UnavailableWeatherForecastProvider(),
                    store: InMemoryWeatherForecastStore(),
                    epochs: InMemoryPressureLocationEpochStore(),
                    access: UnavailableLocationAccessReporter(),
                    preferences: InMemoryWeatherKitPreferenceStore()),
                forecast: previewForecast,
                healthLog: InMemoryHealthSampleStore()),
             // Empty archive, so the preview draws the observed half alone — which is also the
             // state of every device without a location grant.
             forecast: previewForecast,
             // No risk model in the canvas: the card then renders exactly as it does on a
             // device with too little history, which is the state worth having in a preview.
             risk: nil,
             checkInStore: InMemoryCheckInStore(),
             tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
             // No notification centre in a preview: `NoOpNotificationDeliverer` reports itself
             // unauthorised, so nothing is scheduled and no permission prompt appears.
             reminders: CheckInReminderController(checkIns: InMemoryCheckInStore(),
                                                  store: InMemoryNotificationStore(),
                                                  deliverer: NoOpNotificationDeliverer(),
                                                  preferences: InMemoryReminderPreferenceStore()),
             settings: .preview,
             languages: LanguageController(),
             router: NotificationRouter(),
             onDataErased: {})
}
