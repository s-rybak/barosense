import SwiftUI

/// O7 · What Barosense costs (the closing step).
///
/// The last thing onboarding shows, and the step that actually commits: its action writes the
/// profile, prunes the tag vocabulary and leaves the flow. `ReadyStep` used to do all three
/// and now reads "Next" — the retry-on-failure copy moved here with the write.
///
/// ## Why the free week is the only action
///
/// There is no "buy now" on this screen, and therefore **no plan cards either**. The trial
/// starts for every install whether or not anyone taps anything
/// (`SubscriptionController.load`), so the button is not what grants it — it is the
/// acknowledgement.
///
/// The cards were here at first, to say what happens in seven days. They had to go: a card
/// that highlights when you tap it, showing a price, above a button that charges nothing, is a
/// control that appears to do something and does not. Someone who picks "Yearly" and then taps
/// "Start 7 days free" has every reason to believe they have chosen a plan. What the seven days
/// cost is said in the renewal terms further down, in words, where nothing pretends to be
/// selectable.
///
/// That is a product decision and a review one. A hard paywall between finishing setup and
/// seeing the app is a Guideline 3.1.2 conversation nobody needs, and it also sells the wrong
/// thing: what Premium is worth depends entirely on the user's own history, and on day zero
/// they have none. Seven days in, the risk outlook has something to say and the offer can be
/// judged. The paywall is one tap away in Settings for anyone who wants it sooner.
struct PremiumStep: View {

    @Bindable var model: OnboardingModel

    /// `nil` on a build where the store never opened, which is a state this flow is not shown
    /// in — and in previews. The step still draws: everything on it is copy, and the only
    /// thing here that reaches the App Store at all is "Restore purchases".
    let subscription: SubscriptionController?

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: model.step.completedSteps,
            palette: .dark,
            actionTitle: model.failure == nil ? SubscriptionCopy.trialAction : "Try again",
            isActionEnabled: !model.isSaving,
            action: model.advance
        ) {
            VStack(spacing: 20) {
                PremiumOfferView(showsPlans: false, restore: restore)
                    .padding(.top, 8)

                if model.failure != nil {
                    Text("Your answers could not be saved. Check that the device has free space and try again.")
                        .font(Typography.fieldUnit)
                        .foregroundStyle(Palette.markerWarm)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    /// Reachable from onboarding on purpose. Someone reinstalling, or setting up a second
    /// device, meets this screen before they ever reach Settings — and telling them their
    /// subscription is gone until they finish setup and go looking for a restore button is
    /// how a paying user concludes they have been charged twice.
    private func restore() {
        Task { await subscription?.restore() }
    }
}

#Preview {
    PremiumStep(model: OnboardingModel(profileStore: InMemoryUserProfileStore(),
                                       tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                                       sensorAccess: NoOpSensorAccess(),
                                       onFinished: {}),
                subscription: nil)
}
