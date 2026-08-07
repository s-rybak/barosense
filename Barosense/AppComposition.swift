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

            // Seeding runs at every launch by contract — `insertIfAbsent` leaves renamed
            // and archived rows alone, and writes nothing when there is nothing new.
            try await tagStore.insertIfAbsent(WellbeingTag.seeds)

            let profile = try await profileStore.profile()

            self.profileStore = profileStore
            self.tagStore = tagStore
            phase = profile?.hasCompletedOnboarding == true ? .ready : .onboarding
        } catch {
            phase = .unavailable
        }
    }

    func onboardingFinished() {
        phase = .ready
    }
}

/// Chooses between onboarding and the app proper.
struct AppRootView: View {

    let ingest: HealthIngestController
    let pressure: PressureIngestController

    @State private var services = AppServices()

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
                RootView(ingest: ingest, pressure: pressure)
            }
        }
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
