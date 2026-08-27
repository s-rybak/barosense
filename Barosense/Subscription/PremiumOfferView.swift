import SwiftUI

/// What Premium is and what it costs, on the dark side of the palette.
///
/// One view behind all three places the offer appears — the closing onboarding step, the
/// end-of-trial sheet, and the Settings screen — because the *content* is the same offer in
/// all three and only the action underneath it differs. The three containers own their own
/// button: onboarding starts the free week, the sheet and the Settings screen buy.
///
/// Dark in every one of them, including the Settings screen it is pushed onto, which is
/// otherwise the app's lightest surface. That is the one place this file departs from the
/// surrounding design on purpose: the offer is the only screen in Barosense that asks for
/// money, and it should not be mistakable for another row of settings.
struct PremiumOfferView: View {

    /// Which card is filled. A binding, because the button that spends it lives in the
    /// container.
    ///
    /// Defaulted, so a container drawing this with `showsPlans: false` does not have to carry
    /// a piece of state nothing reads — see `PremiumStep`.
    var selection: Binding<SubscriptionPlan> = .constant(.yearly)

    /// What the App Store will sell, and at what price. Empty while it has not answered — a
    /// state this view draws rather than hides, because on a build with no configured products
    /// it is the permanent one.
    var offers: [SubscriptionOffer] = []

    var isLoadingOffers = false

    /// Whether to draw the plan cards at all. False on the Settings screen while a
    /// subscription is already running: there is nothing to choose, and a priced card under an
    /// active subscription reads as a second charge.
    var showsPlans = true

    let restore: () -> Void

    @Environment(\.openURL) private var openURL

    private enum Metrics {
        static let blockSpacing: CGFloat = 22
        static let cardRadius: CGFloat = 16
    }

    var body: some View {
        VStack(spacing: Metrics.blockSpacing) {
            header

            includedList

            if showsPlans { plans }

            freeList

            legal
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Text(SubscriptionCopy.paywallTitle)
                .font(Typography.onboardingTitleCompact)
                .foregroundStyle(Palette.onInk)
                .multilineTextAlignment(.center)

            Text(SubscriptionCopy.paywallSubtitle)
                .font(Typography.onboardingBodySmall)
                .foregroundStyle(Palette.bodyTextOnInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Lists

    /// The three gated surfaces. `PremiumFeature.allCases` rather than a written list, so a
    /// fourth gated screen cannot land without appearing on the screen that sells it.
    private var includedList: some View {
        VStack(alignment: .leading, spacing: 12) {
            OfferSectionLabel(text: SubscriptionCopy.includedHeader)

            ForEach(PremiumFeature.allCases) { feature in
                MarkerRow(text: SubscriptionCopy.included(feature),
                          marker: Palette.markerWarm,
                          markerSize: 10,
                          palette: .dark)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What an expired install keeps, drawn with the same weight as what it loses.
    ///
    /// Not fine print. A paywall that lists only what it takes away invites the reasonable
    /// fear that the app stops recording — which is exactly what it must not do, because a
    /// broken history is what makes a returning subscriber's model worthless
    /// (`PremiumFeature`). Saying so is honest and it is also the better argument.
    private var freeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            OfferSectionLabel(text: SubscriptionCopy.freeHeader)

            ForEach(Array(SubscriptionCopy.freeForever.enumerated()), id: \.offset) { _, line in
                MarkerRow(text: line,
                          marker: Palette.positive,
                          markerSize: 10,
                          palette: .dark)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Plans

    @ViewBuilder
    private var plans: some View {
        VStack(spacing: 10) {
            if isLoadingOffers && offers.isEmpty {
                ProgressView()
                    .tint(Palette.onInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 76)
            } else if offers.isEmpty {
                // Both plans still drawn, at their list price, with the App Store's silence
                // stated underneath. Drawing nothing at all would leave a paywall that never
                // says what it costs; drawing a figure without saying it is unconfirmed would
                // state a price the app cannot charge.
                ForEach(SubscriptionPlan.inDisplayOrder) { plan in
                    PlanCard(plan: plan,
                             price: nil,
                             isSelected: selection.wrappedValue == plan,
                             select: { selection.wrappedValue = plan })
                }

                Text(SubscriptionCopy.offersUnavailable)
                    .font(Typography.settingsCaption)
                    .foregroundStyle(Palette.bodyTextOnInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(offers) { offer in
                    PlanCard(plan: offer.plan,
                             price: offer.displayPrice,
                             isSelected: selection.wrappedValue == offer.plan,
                             select: { selection.wrappedValue = offer.plan })
                }
            }
        }
    }

    // MARK: - Legal

    /// The renewal disclosure, the two links Apple requires beside any subscription, and the
    /// restore action.
    ///
    /// Restore is not optional decoration: a user who reinstalls, or signs in on a second
    /// device, has to be able to get back what they bought without paying twice.
    private var legal: some View {
        VStack(spacing: 12) {
            Button(action: restore) {
                Text(SubscriptionCopy.restoreAction)
                    .font(Typography.linkAction)
                    .foregroundStyle(Palette.onInk)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Text(SubscriptionCopy.renewalTerms)
                .font(Typography.settingsCaption)
                .foregroundStyle(Palette.bodyTextOnInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                LegalLink(title: SubscriptionCopy.termsLink, url: SubscriptionLinks.terms)
                LegalLink(title: SubscriptionCopy.privacyLink, url: SubscriptionLinks.privacy)
            }
        }
    }
}

/// Where the two required documents live.
///
/// Apple's own standard EULA is the terms link unless the app ships one of its own, and it is
/// what this app uses — there is no separate licence to write. The privacy policy is
/// Barosense's and has to be a real, reachable page before submission.
enum SubscriptionLinks {

    /// Apple's standard End User Licence Agreement.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")

    /// **Placeholder.** Points at the App Store's own privacy page so the link is never dead,
    /// and must be replaced with Barosense's published policy before submission — App Review
    /// checks that this one resolves to the app's own document.
    static let privacy = URL(string: "https://www.apple.com/legal/privacy/")
}

/// An all-caps label above a block, on the dark palette.
///
/// Not `SettingsSectionHeader`, which is the same shape on the light one, and not the check-in
/// sheet's `SectionLabel`, which is a different type ramp entirely. Three near-identical
/// headings is worth collapsing the day a fourth appears; today each is one `Text` modifier
/// chain and sharing them would mean a palette parameter on all three.
private struct OfferSectionLabel: View {

    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(Typography.sectionHeader)
            .tracking(0.48)
            .textCase(.uppercase)
            .foregroundStyle(Palette.bodyTextOnInk)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One plan, as a tappable card: name, price, period, and the saving badge where there is one.
private struct PlanCard: View {

    let plan: SubscriptionPlan
    /// The App Store's own string, or `nil` while it has not answered.
    let price: String?
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(SubscriptionCopy.planName(plan))
                        .font(Typography.cardTitle)
                        .foregroundStyle(Palette.onInk)

                    priceLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let percent = plan.savingPercentAgainstMonthly {
                    Text(verbatim: SubscriptionCopy.savingBadge(percent: percent, locale: locale))
                        .font(Typography.captionEmphasis)
                        .foregroundStyle(Palette.positive)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.elevatedInk)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Palette.onInk : Palette.separatorOnInk,
                                  lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The price and its period on one line. `Text(verbatim:)` for the figure, because it is
    /// the App Store's already-formatted string and must not be put through a lookup.
    @ViewBuilder
    private var priceLine: some View {
        if let price {
            HStack(spacing: 4) {
                Text(verbatim: price)
                Text(SubscriptionCopy.planPeriod(plan))
            }
            .font(Typography.settingsCaption)
            .foregroundStyle(Palette.bodyTextOnInk)
        } else {
            Text(SubscriptionCopy.priceUnavailable)
                .font(Typography.settingsCaption)
                .foregroundStyle(Palette.bodyTextOnInk)
        }
    }
}

/// One of the two required legal links.
private struct LegalLink: View {

    let title: LocalizedStringKey
    let url: URL?

    var body: some View {
        if let url {
            Link(destination: url) {
                Text(title)
                    .font(Typography.settingsCaption)
                    .underline()
                    .foregroundStyle(Palette.bodyTextOnInk)
            }
        }
    }
}

#Preview {
    ScrollView {
        PremiumOfferView(selection: .constant(.yearly),
                         offers: [
                            SubscriptionOffer(plan: .yearly,
                                              displayPrice: "€60.00",
                                              isEligibleForIntroOffer: true),
                            SubscriptionOffer(plan: .monthly,
                                              displayPrice: "€9.00",
                                              isEligibleForIntroOffer: true)
                         ],
                         restore: {})
            .padding(24)
    }
    .background(Palette.ink.ignoresSafeArea())
}
