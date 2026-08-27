import Foundation

/// The three surfaces that close when the entitlement lapses.
///
/// An enum rather than three booleans scattered across the views, because "what is behind the
/// paywall" is a product decision that has to be readable in one place — and because the
/// locked-state view takes one of these and draws the right words from it.
///
/// **What is deliberately *not* here is the larger half of the app.** Check-ins, the tag
/// vocabulary, the pressure chart, History, the Health rows, the reminder and the watch stay
/// open on an expired install. That is not generosity: `CLAUDE.md` constraint 5 makes the
/// personal model worthless without a continuous history, and an app that stops recording when
/// a subscription lapses throws away the very thing a returning subscriber would be paying for.
/// The paywall closes what the app *shows*, never what it *collects*.
enum PremiumFeature: String, CaseIterable, Sendable, Identifiable {

    /// The shareable PDF. The most-asked-for single thing in the app, and the one with an
    /// obvious per-use value, which is what makes it the anchor of the paid tier.
    case report

    /// The Insights destination.
    case insights

    /// The risk outlook card at the top of Now — the forward-looking read of the user's own
    /// history. The chart underneath it, including the WeatherKit half, stays open: that is
    /// weather, not a personal read.
    case riskOutlook

    var id: String { rawValue }
}

/// Decides what an entitlement opens. The whole of the paywall's logic, and none of its
/// presentation.
///
/// A free function over a value type rather than a method on a controller, so the rule is
/// reachable from a unit test with a synthetic clock and no store, no StoreKit and no view —
/// the same reason every other decision in `Shared/` is shaped this way.
enum SubscriptionGate {

    /// Whether `feature` may be drawn at `instant`.
    ///
    /// Every gated feature opens and closes together. They are one purchase, so a per-feature
    /// table here would be an abstraction for a second case that does not exist — and the day
    /// it does, this is the one function that changes.
    static func isUnlocked(_ feature: PremiumFeature,
                           status: SubscriptionStatus,
                           asOf instant: Date) -> Bool {
        status.isActive(asOf: instant)
    }

    /// Whether the app should raise the paywall by itself at `instant`.
    ///
    /// Three conditions, and all three matter:
    ///
    /// 1. The trial is genuinely over — not merely "not active", which is also true of an
    ///    install whose trial has not begun.
    /// 2. Nothing paid is carrying the install.
    /// 3. It has not already been offered since the trial ended.
    ///
    /// The third is what makes this a single offer rather than a launch-time interstitial. The
    /// user who dismisses it still reaches the paywall from Settings, from the Insights tab and
    /// from the report row, which is three standing doors — the app does not need a fourth that
    /// opens itself every morning.
    static func shouldOfferPaywall(status: SubscriptionStatus, asOf instant: Date) -> Bool {
        guard status.hasTrialExpired(asOf: instant) else { return false }
        guard let trialEndsAt = status.trialEndsAt else { return false }

        // Compared against the end of the trial rather than against "some time ago": an offer
        // made *during* the trial — from a tap on the Settings card — must not count as the
        // one the expiry is owed.
        guard let lastOfferedAt = status.lastOfferedAt else { return true }
        return lastOfferedAt < trialEndsAt
    }
}
