import SwiftUI

/// What stands in for a gated screen while the subscription is off.
///
/// One view for all three locked surfaces, taking the feature so it can say *what* is behind
/// the lock. A generic "upgrade to continue" is the version of this that the user cannot judge
/// a price against — and on the Insights tab, which they may never have seen unlocked, it
/// would be a wall with no explanation at all.
///
/// It reads on the app's own light surface rather than the paywall's dark one. This is not the
/// offer; it is a screen that is temporarily not here, and dressing it as the sales screen
/// would make three tabs of the app look like advertising.
///
/// The last line is the one that matters most here: recording never stops. Someone whose
/// trial has lapsed has to know their check-ins are still being kept, or the reasonable
/// conclusion is that the week they are not paying for is a week of history lost — which is
/// exactly what would make the subscription not worth resuming. See `PremiumFeature`.
struct PremiumLockedView: View {

    let feature: PremiumFeature

    /// Opens the offer. The container decides whether that is a sheet or a push.
    let showOffer: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            LockMark()

            VStack(spacing: 8) {
                Text(SubscriptionCopy.lockedTitle)
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.heading)

                Text(SubscriptionCopy.lockedBody(feature))
                    .font(Typography.settingsCaption)
                    .foregroundStyle(Palette.bodyText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: showOffer) {
                Text(SubscriptionCopy.lockedAction)
                    .font(Typography.primaryAction)
                    .foregroundStyle(Palette.onInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Palette.ink)
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Text(SubscriptionCopy.lockedStillRecording)
                .font(Typography.settingsCaption)
                .foregroundStyle(Palette.placeholder)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Palette.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: 1)
        }
    }
}

/// A full-screen version of the same stub, for the two destinations that are nothing *but*
/// the gated feature: the Insights tab and the pushed report screen.
struct PremiumLockedScreen: View {

    let feature: PremiumFeature
    let showOffer: () -> Void

    var body: some View {
        ScrollView {
            PremiumLockedView(feature: feature, showOffer: showOffer)
                .padding(.horizontal, SettingsMetrics.screenInset)
                .padding(.vertical, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.ignoresSafeArea())
    }
}

/// The lock.
///
/// An SF Symbol rather than a drawn shape, which is the opposite of the call `TabBarIcons` and
/// `ConfirmationRing` make — and for the reason those two exist: each is a *specific* mark the
/// design file draws, which no symbol matches. A padlock is not; it is the system's own idiom
/// for exactly this, it scales with Dynamic Type on its own, and it stays optically centred at
/// every size.
private struct LockMark: View {

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 34, weight: .regular))
            .foregroundStyle(Palette.inkSubtle)
            .accessibilityHidden(true)
    }
}

#Preview {
    PremiumLockedScreen(feature: .insights, showOffer: {})
}
