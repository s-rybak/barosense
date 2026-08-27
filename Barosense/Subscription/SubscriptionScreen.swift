import SwiftUI

/// The Settings row for the subscription: a dark card carrying the product name and, under it,
/// what the user currently has and until when.
///
/// The one card on that screen drawn on `Palette.ink` rather than white. It is not decoration:
/// this is the only row in Settings that is about money, and the design uses the dark surface
/// exactly where the app changes register — the closing onboarding step, the risk card, the
/// offer screen.
struct SubscriptionSettingsCard: View {

    let subscription: SubscriptionController
    let open: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(SubscriptionCopy.paywallTitle)
                        .font(Typography.cardTitle)
                        .foregroundStyle(Palette.onInk)

                    Text(statusLine)
                        .font(Typography.settingsCaption)
                        .foregroundStyle(Palette.bodyTextOnInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.bodyTextOnInk)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(minHeight: SettingsMetrics.rowMinHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Palette.ink)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Three states, three sentences. The two active ones name the date the entitlement runs
    /// to — which is the fact somebody opens this row to check — and say which of the two it
    /// is, because "until 12 June" means something different when it is a trial that ends than
    /// when it is a subscription that renews.
    private var statusLine: LocalizedStringKey {
        guard let until = subscription.activeUntil else {
            return subscription.status.hasTrialExpired(asOf: .now)
                ? SubscriptionCopy.expired
                : SubscriptionCopy.inactive
        }

        let date = until.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))

        return switch subscription.source {
        case .purchase: SubscriptionCopy.activeUntil(date)
        case .trial, nil: SubscriptionCopy.trialUntil(date)
        }
    }
}

/// M6d · Subscription.
///
/// Pushed from the Settings card. Shows the offer and, while something is already running,
/// what is running and until when.
///
/// The plan cards and the buy button come away only once something has actually been
/// **bought**, not merely while the install is entitled. A trial is an entitlement that is
/// about to end, and the week it runs is when a convinced user most wants to convert — hiding
/// the purchase behind "you already have access" would leave this screen, the one place in the
/// app that sells anything, unable to sell for the first seven days. What a priced card must
/// not sit under is a paid subscription, where it reads as an invitation to be charged twice.
///
/// Not in the Figma file, so it is assembled from the same parts as the rest of the settings
/// flow: the settings navigation bar over the shared `PremiumOfferView`.
struct SubscriptionScreen: View {

    @Bindable var subscription: SubscriptionController

    let back: () -> Void

    @State private var selection: SubscriptionPlan = .yearly

    @Environment(\.locale) private var locale

    /// Whether anything is currently carrying this install — a trial counts.
    private var isEntitled: Bool { subscription.source != nil }

    /// Whether something has been **paid for**. The trial is not this, which is the whole
    /// point: see the note on the type.
    private var isPurchased: Bool { subscription.source == .purchase }

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavigationBar(title: SubscriptionCopy.settingsRow,
                                  back: back,
                                  isOnDarkSurface: true)
                .background(Palette.ink)

            ScrollView {
                VStack(spacing: 18) {
                    if isEntitled { currentStatus }

                    PremiumOfferView(selection: $selection,
                                     offers: subscription.offers,
                                     isLoadingOffers: subscription.isLoadingOffers,
                                     showsPlans: !isPurchased,
                                     restore: restore)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            if !isPurchased { buyButton }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ink.ignoresSafeArea())
        // Deliberately does **not** call `recordPaywallOffered`. That stamp spends the single
        // end-of-trial offer the app is allowed to raise by itself, and a user who navigated
        // here has not been offered anything — burning it would mean the one automatic prompt
        // never appears for anyone who looked at this screen once.
        .task { await subscription.loadOffers() }
        .alert(item: $subscription.failure) { failure in
            Alert(title: Text(failure.message), dismissButton: .default(Text("OK")))
        }
    }

    /// What is running, on the elevated surface so it reads as a statement rather than an
    /// offer.
    private var currentStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(planLine)
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.onInk)

            if let until = subscription.activeUntil {
                Text(SubscriptionCopy.until(
                    until.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
                ))
                .font(Typography.settingsCaption)
                .foregroundStyle(Palette.bodyTextOnInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.elevatedInk)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// The plan's own name while one is bought, and the trial's noun when the free week is what
    /// is carrying the install. Never `trialAction` — that is a button label, and as a heading
    /// over a trial already running it reads as an offer not yet taken.
    private var planLine: LocalizedStringKey {
        guard subscription.source == .purchase, let plan = subscription.status.plan else {
            return SubscriptionCopy.trialStatus
        }
        return SubscriptionCopy.planName(plan)
    }

    private var buyButton: some View {
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
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .padding(.top, 8)
    }

    private func buy() {
        Task { await subscription.purchase(selection) }
    }

    private func restore() {
        Task { await subscription.restore() }
    }
}

#Preview {
    SubscriptionScreen(subscription: SubscriptionController(
        store: InMemorySubscriptionStatusStore(
            SubscriptionStatus(trialStartedAt: .now)
        )
    ), back: {})
}
