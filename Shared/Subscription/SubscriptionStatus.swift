import Foundation

/// What Barosense believes about this install's entitlement, and when that belief runs out.
///
/// A value type with the dates in it rather than a bare `isPremium` flag, because every screen
/// that shows this has to answer "until when" as well as "yes or no" — the Settings card prints
/// the date, and the gate has to re-evaluate as the clock passes it without anything being
/// re-fetched.
///
/// **The clock is a parameter, never `Date()` read inside.** Every question this type answers
/// takes `asOf:`, so a test can walk an install across the end of its trial without sleeping,
/// and so two views rendered in one frame cannot disagree about which side of the boundary
/// they are on.
struct SubscriptionStatus: Equatable, Sendable {

    /// Where the entitlement comes from, if it has one.
    enum Source: String, Sendable, Equatable {
        /// The free stretch every install starts with. Not a purchase — nothing was charged
        /// and nothing renews.
        case trial
        /// A paid subscription the App Store has confirmed.
        case purchase
    }

    /// When this install's free stretch began. `nil` on a status that has never been opened,
    /// which `SubscriptionService` repairs on first read.
    var trialStartedAt: Date?

    /// The plan the App Store says is active, and `nil` when none is.
    var plan: SubscriptionPlan?

    /// When the paid period ends — a renewal date while it keeps renewing, an expiry once it
    /// stops. `nil` for an install that has never bought anything.
    var purchaseExpiresAt: Date?

    /// When the App Store last confirmed the purchase above.
    ///
    /// Exists because StoreKit cannot say "I could not ask". `Transaction.currentEntitlements`
    /// yields nothing both for an account that holds no subscription and for one that could
    /// not be read — a signed-out Apple Account, a restored device before its transactions
    /// have synced, an outage — and the two must not be read alike. Without this, every
    /// empty answer would wipe the cached purchase and lock a paying user out, which is the
    /// one thing the cache exists to stop (`SubscriptionStatusStore`).
    ///
    /// So the distinction is made by time rather than by an error: an empty answer holds the
    /// cached purchase for `SubscriptionGrace.duration` from this stamp and then clears it.
    /// See `reconciled(with:asOf:)`.
    var purchaseConfirmedAt: Date?

    /// When the paywall was last put in front of the user by the app itself.
    ///
    /// Stored so the end-of-trial offer is shown **once** rather than on every activation
    /// after day seven. A paywall that reappears at every launch is nagging, and nagging is
    /// its own review finding.
    var lastOfferedAt: Date?

    init(trialStartedAt: Date? = nil,
         plan: SubscriptionPlan? = nil,
         purchaseExpiresAt: Date? = nil,
         purchaseConfirmedAt: Date? = nil,
         lastOfferedAt: Date? = nil) {
        self.trialStartedAt = trialStartedAt
        self.plan = plan
        self.purchaseExpiresAt = purchaseExpiresAt
        self.purchaseConfirmedAt = purchaseConfirmedAt
        self.lastOfferedAt = lastOfferedAt
    }

    // MARK: - Folding in the App Store's answer

    /// This status with `entitlement` folded into its purchase half.
    ///
    /// A positive answer is taken as given and stamped: the App Store is the authority, and
    /// what it reports is what the install has.
    ///
    /// An **empty** answer is the interesting one, because it has two causes that look
    /// identical from here — the account genuinely holds nothing, or it could not be read at
    /// all (see `purchaseConfirmedAt`). Clearing on the first empty answer is what would lock a
    /// subscriber out of what they paid for; never clearing would hand a refunded account free
    /// access until its cached expiry, which for the yearly plan is most of a year. So an empty
    /// answer holds a still-live cached purchase for `SubscriptionGrace.duration` and no
    /// longer, and clears one whose own expiry has already passed immediately.
    func reconciled(with entitlement: PurchasedEntitlement?, asOf instant: Date) -> Self {
        var updated = self

        if let entitlement {
            updated.plan = entitlement.plan
            updated.purchaseExpiresAt = entitlement.expiresAt
            updated.purchaseConfirmedAt = instant
            return updated
        }

        // Nothing cached, or a cached period that has run out on its own date. There is no
        // entitlement to protect, so the empty answer is simply true.
        guard let expiry = purchaseExpiresAt, expiry > instant else {
            updated.plan = nil
            updated.purchaseExpiresAt = nil
            updated.purchaseConfirmedAt = nil
            return updated
        }

        // A row written before this field existed reads back with no stamp. Starting its grace
        // now rather than reading it as never-confirmed is what stops the window from
        // restarting on every activation and becoming unbounded — it is persisted with the
        // rest of the status.
        let confirmed = purchaseConfirmedAt ?? instant
        updated.purchaseConfirmedAt = confirmed

        guard instant.timeIntervalSince(confirmed) >= SubscriptionGrace.duration else {
            return updated
        }

        updated.plan = nil
        updated.purchaseExpiresAt = nil
        updated.purchaseConfirmedAt = nil
        return updated
    }

    /// When the trial runs out, or `nil` before it has started.
    var trialEndsAt: Date? {
        trialStartedAt?.addingTimeInterval(SubscriptionTrial.duration)
    }

    /// Where the current entitlement comes from at `instant`, or `nil` when there is none.
    ///
    /// The purchase is checked first. Someone who buys on day two is a subscriber for the rest
    /// of that week, not a trialist — and their Settings card has to print the renewal date
    /// rather than a trial that is about to end under a paid subscription.
    func source(asOf instant: Date) -> Source? {
        if let purchaseExpiresAt, purchaseExpiresAt > instant { return .purchase }
        if let trialEndsAt, trialEndsAt > instant { return .trial }
        return nil
    }

    /// Whether the paid features are open at `instant`.
    func isActive(asOf instant: Date) -> Bool {
        source(asOf: instant) != nil
    }

    /// The date the Settings card prints: the end of whichever entitlement is currently
    /// carrying the install, and `nil` when none is.
    func activeUntil(asOf instant: Date) -> Date? {
        switch source(asOf: instant) {
        case .purchase: purchaseExpiresAt
        case .trial: trialEndsAt
        case nil: nil
        }
    }

    /// Whole days left before `activeUntil`, floored at zero, or `nil` when nothing is active.
    ///
    /// Rounded **up**, so the last partial day still reads as "1 day left" rather than "0".
    func daysRemaining(asOf instant: Date) -> Int? {
        guard let until = activeUntil(asOf: instant) else { return nil }

        let seconds = until.timeIntervalSince(instant)
        guard seconds > 0 else { return 0 }
        return Int((seconds / (24 * 3600)).rounded(.up))
    }

    /// Whether the trial has been used up and nothing paid has replaced it.
    ///
    /// The one state the end-of-trial offer is for. Distinct from "not active": an install
    /// whose trial has not started yet is also not active, and must not be shown an expiry
    /// message about a stretch it never had.
    func hasTrialExpired(asOf instant: Date) -> Bool {
        guard let trialEndsAt else { return false }
        return trialEndsAt <= instant && !isActive(asOf: instant)
    }
}
