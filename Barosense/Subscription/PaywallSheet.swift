import SwiftUI

/// The offer as a sheet: what the app raises by itself when the free week runs out, and what
/// every locked screen's button opens.
///
/// A sheet rather than a pushed screen because it has to be reachable from three different
/// places in three different navigation stacks, and because it must always be dismissible.
/// There is no version of this the user cannot get out of — the app underneath keeps working
/// without a subscription, so a paywall that cannot be closed would be blocking a working app
/// behind a purchase.
/// How the offer sheet came to be on screen.
///
/// The two routes are not interchangeable. The app is allowed to raise the offer by itself
/// **once**, when the free week runs out, and `SubscriptionController.recordPaywallOffered`
/// is what spends that one chance. A user who went looking for the paywall — from a locked
/// screen, or from Settings — has not been offered anything, so opening it that way must not
/// spend it, or the one automatic prompt never appears for anyone who ever tapped a lock.
///
/// Carried as state rather than passed as a bare `Bool` at the call site, so "the sheet is
/// open" and "this is the automatic one" cannot drift apart — they are one value.
enum PaywallOrigin: Identifiable, Equatable {

    /// Raised by the app at the end of the trial. Spends the one automatic offer.
    case automatic

    /// Opened by the user. Spends nothing.
    case requested

    var id: Self { self }
}

struct PaywallSheet: View {

    @Bindable var subscription: SubscriptionController

    /// Whether the app raised this by itself. See `PaywallOrigin`.
    let isAutomatic: Bool

    let dismiss: () -> Void

    @State private var selection: SubscriptionPlan = .yearly

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    if subscription.hasTrialExpired {
                        Text(SubscriptionCopy.expired)
                            .font(Typography.captionEmphasis)
                            .foregroundStyle(Palette.markerWarm)
                            .frame(maxWidth: .infinity)
                    }

                    PremiumOfferView(selection: $selection,
                                     offers: subscription.offers,
                                     isLoadingOffers: subscription.isLoadingOffers,
                                     restore: restore)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ink.ignoresSafeArea())
        .task {
            // Stamped **here**, on the sheet that is now on screen, rather than by whoever set
            // the state that asked for it. Asking is a request: SwiftUI presents one sheet per
            // view, the root has four, and a check-in raised by a notification tap on the same
            // frame wins. A stamp written at the request would spend the app's one automatic
            // offer on a sheet nobody saw, and `shouldOfferPaywall` never comes back.
            //
            // Before `loadOffers`, not after: the offer has been made the moment this is
            // readable, and making the stamp wait behind a StoreKit round trip would lose it if
            // the user closed the app while prices were still loading.
            if isAutomatic { await subscription.recordPaywallOffered() }

            await subscription.loadOffers()
        }
        .alert(item: $subscription.failure) { failure in
            Alert(title: Text(failure.message), dismissButton: .default(Text("OK")))
        }
    }

    /// The buy action and the way out, pinned below the scroll.
    ///
    /// "Not now" is a plain text button rather than a corner glyph, and it is always there.
    /// A dismissal that has to be found is a dismissal the user resents having found.
    private var actions: some View {
        VStack(spacing: 0) {
            Button(action: buy) {
                HStack(spacing: 8) {
                    if subscription.isPurchasing {
                        ProgressView().tint(Palette.ink)
                    }

                    Text(subscription.isPurchasing
                        ? SubscriptionCopy.purchasingAction
                        : SubscriptionCopy.subscribeAction)
                }
                .font(Typography.primaryAction)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Palette.onInk)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(subscription.isPurchasing)
            .opacity(subscription.isPurchasing ? 0.6 : 1)

            Button(action: dismiss) {
                Text(SubscriptionCopy.maybeLaterAction)
                    .font(Typography.tertiaryAction)
                    .foregroundStyle(Palette.bodyTextOnInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    /// Dismisses on success rather than leaving the user on a paywall for something they have
    /// just bought. `isActive` is the check, not "no error": a cancelled purchase reports
    /// nothing and must leave the sheet where it is.
    private func buy() {
        Task {
            await subscription.purchase(selection)
            if subscription.source == .purchase { dismiss() }
        }
    }

    private func restore() {
        Task {
            await subscription.restore()
            if subscription.source == .purchase { dismiss() }
        }
    }
}

#Preview {
    PaywallSheet(subscription: SubscriptionController(store: InMemorySubscriptionStatusStore()),
                 isAutomatic: false,
                 dismiss: {})
}
