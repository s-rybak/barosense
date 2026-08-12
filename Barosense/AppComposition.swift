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

    /// Everything the settings tab reads. `nil` until `start()` has opened the store —
    /// which is also the only state in which the tab is not on screen.
    private(set) var settings: SettingsDependencies?

    /// The sensor logs. Opened by `BarosenseApp` because the ingest controllers need them
    /// at launch, and handed here so an erase reaches them too — a "delete my data" that
    /// only knew about the profile store would leave the barometer history behind.
    private let healthLog: any HealthSampleStore
    private let pressureLog: any PressureSampleStore
    private let healthAccess: any HealthAccessReporting

    init(healthLog: any HealthSampleStore,
         pressureLog: any PressureSampleStore,
         healthAccess: any HealthAccessReporting = HealthKitAccessReporter()) {
        self.healthLog = healthLog
        self.pressureLog = pressureLog
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

            // Seeding runs at every launch by contract — `insertIfAbsent` leaves renamed
            // and archived rows alone, and writes nothing when there is nothing new.
            try await tagStore.insertIfAbsent(WellbeingTag.seeds)

            let profile = try await profileStore.profile()

            self.profileStore = profileStore
            self.tagStore = tagStore
            self.checkInStore = checkInStore
            self.settings = SettingsDependencies(profileStore: profileStore,
                                                 tagStore: tagStore,
                                                 checkInStore: checkInStore,
                                                 healthLog: healthLog,
                                                 pressureLog: pressureLog,
                                                 healthAccess: healthAccess)
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

    @State private var services: AppServices
    @State private var languages = LanguageController()

    init(ingest: HealthIngestController,
         pressure: PressureCollectionController,
         healthLog: any HealthSampleStore,
         pressureLog: any PressureSampleStore) {
        self.ingest = ingest
        self.pressure = pressure
        _services = State(initialValue: AppServices(healthLog: healthLog,
                                                    pressureLog: pressureLog))
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
                             checkInStore: checkInStore,
                             tagStore: tagStore,
                             settings: services.settings,
                             languages: languages,
                             onDataErased: { await services.restartOnboarding() })
                }
            }
        }
        // The language row in Settings takes effect here and nowhere else: SwiftUI resolves
        // every `LocalizedStringKey` in the tree against this locale, so a change repaints
        // the whole app in the new language without a relaunch. iOS's own idea of the app
        // language moves separately, at the next launch — see
        // `UserDefaultsLanguagePreferenceStore`.
        .environment(\.locale, languages.locale)
        .task { await services.start() }
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
