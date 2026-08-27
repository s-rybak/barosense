import SwiftUI

/// Where a settings row leads.
enum SettingsRoute: Hashable {
    case editProfile
    case report
    case language
    case contact
    case subscription
}

/// M6 · Settings (Figma `7:1246`).
///
/// **My meds** is deliberately absent rather than drawn dead: it is deferred, and a row that
/// leads nowhere teaches the user the list is unreliable. It comes back with the feature.
///
/// **Barometer Premium** was absent for the same reason and is now here, because there is a
/// purchase behind it — see `SubscriptionSettingsCard`.
struct SettingsScreen: View {

    let dependencies: SettingsDependencies
    let languages: LanguageController

    /// What this install is entitled to. `nil` only on a build where the store never opened —
    /// see `RootView.subscription` — which hides the card and leaves the report row open.
    let subscription: SubscriptionController?

    /// Raised while a destination is pushed, so the root can take the tab bar away —
    /// the pushed screens in the design have no tab bar under them.
    @Binding var isDetailPresented: Bool

    @Environment(\.scenePhase) private var scenePhase

    @State private var model: SettingsModel
    @State private var path: [SettingsRoute] = []

    /// Raised after an Edit Profile save, which is the one place in the app where the tag
    /// vocabulary changes outside onboarding. Anything holding a copy of that vocabulary and
    /// unable to observe the store — the paired watch — is refreshed through here.
    private let onVocabularyChanged: () async -> Void

    init(dependencies: SettingsDependencies,
         languages: LanguageController,
         subscription: SubscriptionController? = nil,
         isDetailPresented: Binding<Bool>,
         onDataErased: @escaping () async -> Void,
         onRemindersChanged: @escaping () async -> Void = {},
         onVocabularyChanged: @escaping () async -> Void = {}) {
        self.dependencies = dependencies
        self.languages = languages
        self.subscription = subscription
        self.onVocabularyChanged = onVocabularyChanged
        _isDetailPresented = isDetailPresented
        // The calendar is handed over rather than read from the environment, as on History:
        // this model is built in `init`, before an environment exists, and it decides which
        // day the notification count is taken over.
        _model = State(initialValue: SettingsModel(dependencies: dependencies,
                                                   calendar: languages.calendar,
                                                   onDataErased: onDataErased,
                                                   onRemindersChanged: onRemindersChanged))
    }

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationDestination(for: SettingsRoute.self) { route in
                    destination(for: route)
                        .toolbar(.hidden, for: .navigationBar)
                }
        }
        .task { await model.load() }
        // `.task` fires when the screen appears and never again, so without this the row
        // would still be showing the pre-grant state after the trip to the Health app that
        // this screen itself sends the user on. The switch is the one row here whose value
        // another app can change while Barosense is in the background.
        //
        // Costs one reload per foreground activation, and only while Settings is on screen
        // — the tab is a `switch` case, so this view does not exist on the other tabs. One
        // authorisation-status call plus three `limit: 1` existence queries, in the
        // foreground, on a user-initiated return.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.load() }
        }
        .onChange(of: path) { _, newPath in
            isDetailPresented = !newPath.isEmpty
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            VStack(spacing: SettingsMetrics.blockSpacing) {
                Text("Settings")
                    .font(Typography.screenHeading)
                    .foregroundStyle(Palette.heading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)

                profileCard
                preferencesCard
                WeatherKitCard(model: model)
                RemindersCard(model: model)
                subscriptionCard
                reportCard
                contactCard
                destructiveActions
            }
            .padding(.horizontal, SettingsMetrics.screenInset)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Palette.surface.ignoresSafeArea())
        .scrollBounceBehavior(.basedOnSize)
        // The explanation always precedes the system prompt, and nothing else on this screen
        // can reach iOS. See `LocationPrimer`.
        .sheet(isPresented: $model.isExplainingLocation) {
            LocationPrimer(onAccept: { Task { await model.requestLocationAccess() } },
                           onDecline: model.declineLocationAccess)
        }
        .alert("Delete my data?", isPresented: $model.isConfirmingErase) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await model.eraseEverything() }
            }
        } message: {
            // One literal, joined with line continuations rather than `+`. A `+` between
            // two literals types the expression as `String`, which resolves `Text` to its
            // verbatim initialiser — the key would silently never reach the catalogue.
            //
            // The last sentence is the honest half. The erase empties Barosense's copy;
            // the rows in the Health app belong to Health and were only ever read, so
            // finishing onboarding again does re-read them. Without saying so, the first
            // sentence reads as a promise the app cannot keep.
            Text("""
                This removes your profile, your check-ins, your tags, and every pressure and \
                Health reading stored on this device. It can't be undone, and Barosense \
                starts again from onboarding. Your Health app keeps its own readings — \
                Barosense reads them again only once you set it up.
                """)
        }
        .alert("Nothing to reset yet", isPresented: $model.isShowingLearnedDataNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("""
                Barosense hasn't built a personal model from your history yet. This will \
                clear what it has learned once your forecast is running.
                """)
        }
        .alert("Some data is still on this device",
               isPresented: eraseFailureBinding) {
            Button("OK", role: .cancel) { model.dismissEraseFailure() }
        } message: {
            Text("Barosense could not empty every store. Try again — nothing was sent anywhere.")
        }
        .overlay {
            if model.eraseState == .erasing {
                erasingOverlay
            }
        }
    }

    // MARK: - Cards

    /// Avatar, name and the way into the editor (Figma `7:1261`).
    private var profileCard: some View {
        Button {
            path.append(.editProfile)
        } label: {
            HStack(spacing: 14) {
                ProfileAvatar(imageData: model.profile?.avatarImageData,
                              initial: model.profile?.initial ?? "",
                              diameter: 48,
                              font: Typography.avatarInitialCompact)

                VStack(alignment: .leading, spacing: 2) {
                    profileName
                        .font(Typography.cardTitle)
                        .foregroundStyle(Palette.heading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Edit profile")
                        .font(Typography.settingsCaption)
                        .foregroundStyle(Palette.placeholder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                SettingsChevron()
            }
            .padding(15)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Palette.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: 1)
        }
    }

    /// The user's own words when they gave a name, app copy when they did not.
    private var profileName: Text {
        guard let name = model.profile?.displayName, !name.isEmpty else {
            return Text("Your profile")
        }
        return Text(verbatim: name)
    }

    /// Apple Health and Language (Figma `7:1270`).
    private var preferencesCard: some View {
        SettingsCard {
            HealthRow(model: model)

            SettingsRowDivider()

            LocationRow(model: model)

            SettingsRowDivider()

            SettingsNavigationRow(title: "Language",
                                  value: Text(verbatim: languages.language.endonym)) {
                path.append(.language)
            }
        }
    }

    /// The subscription, on the dark surface. Directly above the report row it governs, so the
    /// one paid thing in this tab and the card that explains it are read together.
    @ViewBuilder
    private var subscriptionCard: some View {
        if let subscription {
            SubscriptionSettingsCard(subscription: subscription) {
                path.append(.subscription)
            }
        }
    }

    /// The way to a shareable document. On its own card rather than beside Language: it is the
    /// one row here that produces a file and hands it to somebody else, and grouping it with
    /// two preferences would bury that.
    private var reportCard: some View {
        SettingsCard {
            SettingsNavigationRow(title: ReportScreenCopy.settingsRow) {
                path.append(.report)
            }
        }
    }

    private var contactCard: some View {
        SettingsCard {
            SettingsNavigationRow(title: "Contact us") {
                path.append(.contact)
            }
        }
    }

    private var destructiveActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            DestructiveActionRow(title: "Reset learned data") {
                model.isShowingLearnedDataNotice = true
            }

            DestructiveActionRow(title: "Delete my data") {
                model.confirmEraseEverything()
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Erase

    private var eraseFailureBinding: Binding<Bool> {
        Binding(
            get: {
                if case .failed = model.eraseState { return true }
                return false
            },
            set: { isPresented in
                if !isPresented { model.dismissEraseFailure() }
            }
        )
    }

    private var erasingOverlay: some View {
        ZStack {
            Palette.surface.opacity(0.9).ignoresSafeArea()
            ProgressView()
        }
        .accessibilityLabel(Text("Deleting your data"))
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(for route: SettingsRoute) -> some View {
        switch route {
        case .editProfile:
            EditProfileScreen(dependencies: dependencies,
                              back: { path.removeLast() },
                              onSaved: {
                                  Task {
                                      await model.load()
                                      await onVocabularyChanged()
                                  }
                              },
                              onDeleteRequested: {
                                  path.removeAll()
                                  model.confirmEraseEverything()
                              })

        case .report:
            // Gated at the destination rather than inside the report screen: past the trial
            // there is nothing to show, and building a preview the user cannot share would
            // spend a full pass over the check-in and barometer tables to draw a stub over it.
            if let subscription, !subscription.isUnlocked(.report) {
                VStack(spacing: 0) {
                    SettingsNavigationBar(title: ReportScreenCopy.title,
                                          back: { path.removeLast() })

                    PremiumLockedScreen(feature: .report) { path.append(.subscription) }
                }
                .background(Palette.surface.ignoresSafeArea())
            } else {
                ReportScreen(dependencies: dependencies,
                             languages: languages,
                             back: { path.removeLast() })
            }

        case .subscription:
            if let subscription {
                SubscriptionScreen(subscription: subscription, back: { path.removeLast() })
            }

        case .language:
            LanguageScreen(languages: languages, back: { path.removeLast() })

        case .contact:
            ContactScreen(back: { path.removeLast() })
        }
    }
}

/// Where the forecast comes from.
///
/// A card of its own rather than a fourth row under Language, because this is the one switch on
/// the screen that governs whether anything leaves the device at all — and because the caption
/// has to state the cost of turning it off, which is a sentence rather than a label.
private struct WeatherKitCard: View {

    let model: SettingsModel

    var body: some View {
        SettingsCard {
            SettingsToggleRow(title: "Apple Weather", caption: caption, isOn: binding)
        }
    }

    /// Written straight through, unlike every other switch on this screen. There is no system
    /// authorisation behind it and nothing outside the app can change it, so "off" has exactly
    /// one meaning and the setter has nothing to interpret.
    private var binding: Binding<Bool> {
        Binding(get: { model.isWeatherKitOn },
                set: { model.setWeatherKitEnabled($0) })
    }

    /// The caption says what switching off costs, and says it accurately: the forecast does not
    /// disappear, it gets shorter and less certain. Wording that claimed otherwise would be
    /// false — see `WeatherKitPrimer`.
    private var caption: LocalizedStringKey {
        model.isWeatherKitOn
            ? "Extends the pressure chart a few days ahead. Sends only your approximate area and the time."
            : "Barosense is building the forecast from your own readings — a few hours ahead, and roughly."
    }
}

/// Apple Health: whether Barosense may read it, and what it can actually see.
///
/// A view of its own for the reason `LocationRow` below is one — the switch is written to
/// through an interpreted tap and the caption has five wordings, and both belong next to the
/// control they drive rather than in the screen that lists it.
private struct HealthRow: View {

    let model: SettingsModel

    var body: some View {
        SettingsToggleRow(title: "Apple Health",
                          caption: caption,
                          isOn: binding,
                          isEnabled: model.health.isInteractive)
    }

    /// The switch reflects what Barosense can actually read from Health, not what it has
    /// asked for. Anything less than the whole read set leaves it off.
    ///
    /// Writing to it never sets it. The setter runs the action the current state allows
    /// (show the sheet, re-check, or send the user to Health) and leaves the displayed
    /// value to `model.load()`, so the switch cannot show a state HealthKit does not agree
    /// with — including the case where the user answers the sheet with a refusal and the
    /// switch has to fall straight back to off.
    private var binding: Binding<Bool> {
        Binding(
            get: { model.health.isConnected },
            set: { _ in
                Task {
                    if await model.toggleHealthAccess() == .needsHealthApp {
                        HealthAppLink.open()
                    }
                }
            }
        )
    }

    /// None of these say "denied". iOS does not reveal a read refusal, and an empty Health
    /// store looks exactly the same from here, so each line states what was observed and
    /// points at the one place that can actually settle it.
    private var caption: LocalizedStringKey? {
        switch model.health.access {
        case .unavailable:
            "Health data isn't available on this device."
        case .notRequested:
            "Fills in sleep, resting heart rate and blood oxygen for you."
        case .requested where model.health.hasNothingReadable:
            "Barosense can't read anything from Health. Open Health to check what it may read."
        case .requested where !model.health.isConnected:
            "Barosense can read only part of your Health data. Open Health to check what it may read."
        case .requested where !model.health.hasReadings:
            "Nothing read in the last 7 days. Open Health to check what Barosense may read."
        case .requested:
            nil
        }
    }
}

/// The location permission, and which place the forecast is about.
///
/// A view of its own for the same reason `RemindersCard` is one: the state machine behind the
/// switch has four outcomes and the caption has five wordings, and inlining both leaves the
/// settings screen carrying logic that belongs next to the control it drives.
private struct LocationRow: View {

    let model: SettingsModel

    var body: some View {
        SettingsToggleRow(title: "Location",
                          caption: caption,
                          isOn: binding,
                          isEnabled: model.location.isInteractive)
    }

    /// Written to the same way the Apple Health switch is. Off means three different things
    /// here — never asked, refused, or services off device-wide — and each needs a different
    /// action, so the tap is interpreted by the model and the displayed value is left to
    /// `model.load()`.
    private var binding: Binding<Bool> {
        Binding(
            get: { model.location.isConnected },
            set: { _ in
                Task {
                    switch await model.toggleLocationAccess() {
                    case .needsExplanation: model.isExplainingLocation = true
                    case .needsSystemSettings: LocationSettingsLink.open()
                    case .unavailable: break
                    }
                }
            }
        )
    }

    /// The granted case names the place rather than the permission, because that is the fact
    /// the user came to check: *which* place is the forecast about. Reduced accuracy is
    /// deliberately never mentioned — it is the accuracy the app asks for and the only one it
    /// can use, so calling it out would invite the user to "fix" something that is not broken.
    private var caption: LocalizedStringKey? {
        switch model.location.access {
        case .unavailable:
            "Location services are turned off on this device."
        case .notRequested:
            "Lets Barosense fetch the pressure forecast for your area."
        case .denied:
            "Location is off for Barosense in iOS Settings. The forecast falls back to your own readings."
        case .granted where model.locationPlaceDescription != nil:
            // Interpolating an already-resolved string into a key keeps the sentence
            // translatable while the place name itself stays the geocoder's words.
            "Forecast for \(model.locationPlaceDescription ?? "")"
        case .granted:
            "Barosense will name your area once it has a fix."
        }
    }
}

/// The check-in reminder and what it costs the user in interruptions.
///
/// A card of its own rather than two more rows under Apple Health. The count row only makes
/// sense next to the switch that produces it, and a "3" sitting under a language picker
/// would be a number with no subject.
private struct RemindersCard: View {

    let model: SettingsModel

    var body: some View {
        SettingsCard {
            SettingsToggleRow(title: "Check-in reminder",
                              caption: caption,
                              isOn: binding)

            SettingsRowDivider()

            SettingsValueRow(title: "Notifications today",
                             value: Text("\(model.reminders.countedToday) of \(model.reminders.dailyLimit)"),
                             caption: "The daily cap, across every kind of notification.")
        }
    }

    /// Written to the same way the Apple Health switch is, and for the same reason: off means
    /// two different things here — the user turned it off, or iOS is refusing to deliver it —
    /// and only the model can tell them apart. The setter runs whatever the current state
    /// allows and leaves the displayed value to `model.load()`, so the switch cannot show a
    /// state iOS disagrees with.
    private var binding: Binding<Bool> {
        Binding(
            get: { model.isReminderOn },
            set: { _ in
                Task {
                    if await model.toggleReminder() == .needsSystemSettings {
                        NotificationSettingsLink.open()
                    }
                }
            }
        )
    }

    /// Says what the reminder is for, and — when it is wanted but not arriving — names the one
    /// place that can fix it.
    private var caption: LocalizedStringKey {
        model.reminders.isBlockedBySystem
            ? "Notifications are turned off for Barosense in iOS Settings."
            : "Asks how you're feeling, at the time of day you usually check in."
    }
}

extension UserProfile {

    /// First character of the name, for the avatar's fallback. Empty when there is no
    /// name — the design's dark disc stands on its own.
    ///
    /// `.uppercased()` with no locale argument would turn a Turkish "i" into "I" rather
    /// than "İ"; the name is the user's, so it is folded the way *their* locale folds it.
    var initial: String {
        guard let first = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return ""
        }
        return String(first).uppercased(with: .current)
    }
}

#Preview {
    SettingsScreen(dependencies: .preview,
                   languages: LanguageController(store: UserDefaultsLanguagePreferenceStore()),
                   isDetailPresented: .constant(false),
                   onDataErased: {})
}
