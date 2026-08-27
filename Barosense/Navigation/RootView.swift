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

    /// What this install is entitled to. `nil` only while the store is still opening, which is
    /// a state this view is never shown in — optional rather than force-unwrapped at the
    /// composition root, like the two above it.
    ///
    /// A `nil` here leaves every gated surface **open**. That is the deliberate direction: the
    /// failure mode of a missing entitlement reader must be a user who sees a feature they
    /// might not have paid for, never a paying user locked out by a store that would not open.
    let subscription: SubscriptionController?

    let languages: LanguageController

    /// Where a tapped notification wants to go. Owned by `BarosenseApp`, because a tap can be
    /// delivered before this view exists.
    let router: NotificationRouter

    let onDataErased: () async -> Void

    /// The user edited their tag vocabulary. Defaulted so previews and tests that do not
    /// care about the watch stay one line — see `WatchBridge.refreshTags()` for what the
    /// real one does and why the watch cannot notice this on its own.
    var onVocabularyChanged: () async -> Void = {}

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

    /// Raised while a tab has something pushed. The pushed screens draw their own navigation
    /// bar and, in the design, no tab bar under them.
    ///
    /// One flag for every tab rather than one per tab: only one destination is on screen at a
    /// time, so a second flag could only ever disagree with this one. Settings and Insights
    /// both write it, and `onChange(of: selection)` below lowers it on any tab change.
    @State private var isDetailPresented = false

    /// Which offer is on screen, and `nil` for none.
    ///
    /// Sequenced behind the two primers rather than shown beside them — see
    /// `isShowingWeatherPrimer` — and behind them deliberately in that order: the reminder and
    /// the WeatherKit trade are questions the app needs answered to work properly, and asking
    /// for money in front of either is how both get dismissed unread.
    ///
    /// Carries *how* the sheet was opened rather than only whether it is open, because the two
    /// routes spend different things — see `PaywallOrigin`. It does not carry whether the trial
    /// has ended: that is the controller's to answer, not this view's to remember
    /// (`SubscriptionController.hasTrialExpired`).
    @State private var paywall: PaywallOrigin?

    /// How tall the tab bar currently is, measured and published for the screens that have to
    /// re-apply it themselves. See `EnvironmentValues.tabBarInset`.
    @State private var tabBarInset: CGFloat = 0

    var body: some View {
        ZStack {
            Palette.surface.ignoresSafeArea()

            destination
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isDetailPresented {
                BarosenseTabBar(selection: tabBarSelection)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        tabBarInset = height
                    }
                    .transition(.move(edge: .bottom))
            }
        }
        // The inset above does not reach a screen that puts a `NavigationStack` between itself
        // and its content, so the ones that do read this and put it back. See
        // `EnvironmentValues.tabBarInset`.
        .environment(\.tabBarInset, tabBarInset)
        .animation(.easeInOut(duration: 0.2), value: isDetailPresented)
        .onChange(of: selection) { _, _ in
            // Leaving a tab while a detail is pushed would otherwise strand the tab bar hidden
            // on a tab that has no way to bring it back. Lowered on every change rather than on
            // a named set of tabs: the tab being left is the one that raised it, whichever it
            // was, and its own `NavigationStack` keeps its path for the return.
            isDetailPresented = false
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
                // Where a renewal, a cancellation or a refund made on another device shows
                // up, and where the gate closes on a trial that ran out while the app was in
                // the background. Answered from StoreKit's on-device cache and writes nothing
                // when the answer has not changed — see `SubscriptionController.reconcile`.
                refreshEntitlement()
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
        .sheet(item: $paywall) { origin in
            if let subscription {
                PaywallSheet(subscription: subscription,
                             isAutomatic: origin == .automatic) { paywall = nil }
            }
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
                return
            }

            offerPaywallIfTrialEnded()
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
                      checkInRevision: checkInRevision,
                      isOutlookUnlocked: isUnlocked(.riskOutlook),
                      showOffer: showOffer)
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
                               subscription: subscription,
                               isDetailPresented: $isDetailPresented,
                               onDataErased: onDataErased,
                               onRemindersChanged: reconcileReminders,
                               onVocabularyChanged: onVocabularyChanged)
            }
        case .insights:
            // Takes the whole store bundle because the report it pushes to takes the whole
            // store bundle — see `InsightsScreen.dependencies`. Absent while the store is still
            // opening, which is a state this view is never shown in.
            //
            // Gated as a whole destination: it is one of the three paid surfaces, and an
            // install past its trial must not reach it by a route the paywall does not cover.
            if isUnlocked(.insights) {
                if let settings {
                    InsightsScreen(dependencies: settings,
                                   languages: languages,
                                   risk: risk,
                                   isDetailPresented: $isDetailPresented)
                        // Re-identified on `checkInRevision` so a check-in written from the sheet
                        // reaches the tag counts and the sparkline, and on the language for the
                        // reason History is: the seven-day trace is named by weekday out of the
                        // calendar the model was built with.
                        .id("\(checkInRevision)-\(languages.language.rawValue)")
                }
            } else {
                PremiumLockedScreen(feature: .insights, showOffer: showOffer)
            }
        }
    }

    /// Whether a gated surface may be drawn.
    ///
    /// Open when there is no controller at all. See the note on `subscription` — the failure
    /// mode of a store that would not open must never be a paying user locked out.
    private func isUnlocked(_ feature: PremiumFeature) -> Bool {
        subscription?.isUnlocked(feature) ?? true
    }

    /// Opens the offer from a locked screen.
    ///
    /// Takes no feature: all three unlock together, so there is one offer and it is the same
    /// one whichever stub was tapped. Not an automatic offer either, so it does **not** spend
    /// the one end-of-trial prompt — see `SubscriptionController.recordPaywallOffered`.
    private func showOffer() {
        paywall = .requested
    }

    /// The single automatic offer, raised once after the free week runs out.
    ///
    /// Asks for the sheet and **stamps nothing**. The stamp is what spends the one automatic
    /// offer the app is allowed to make, and it is written by the sheet itself once it is on
    /// screen — see `PaywallSheet.isAutomatic`.
    ///
    /// That split is the whole point. Setting this state is a request, not a guarantee: SwiftUI
    /// presents one sheet per view, this view has four, and a check-in raised by a notification
    /// tap on the same frame wins. Stamping here would spend the offer on a sheet that never
    /// appeared, and `shouldOfferPaywall` is false for ever afterwards — so the one moment the
    /// whole feature exists for would be dropped in silence. Left unstamped, the offer stays
    /// owed and is made again on the next activation.
    private func offerPaywallIfTrialEnded() {
        guard let subscription, subscription.shouldOfferPaywall else { return }

        paywall = .automatic
    }

    private func refreshEntitlement() {
        Task {
            await subscription?.reconcile()
            // A trial that ran out while the app was backgrounded is only noticed here, so the
            // offer that was owed at the boundary is made on the return rather than waiting
            // for the next cold launch. Also where an offer that was asked for but lost the
            // frame to another sheet gets asked for again.
            offerPaywallIfTrialEnded()
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
             // No StoreKit in a canvas: the controller sells nothing and reports no
             // entitlement, so a preview refresh cannot put an App Store sheet on screen.
             subscription: SubscriptionController(store: InMemorySubscriptionStatusStore()),
             languages: LanguageController(),
             router: NotificationRouter(),
             onDataErased: {})
}
