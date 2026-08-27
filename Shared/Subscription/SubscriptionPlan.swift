import Foundation

/// The two things a user can buy, and the only two.
///
/// The raw value is the App Store product identifier. It is storage *and* protocol: it is
/// written into the subscription row, and it is what `Product.products(for:)` is asked for.
/// Renaming one orphans both the local row and the App Store product, so these strings are
/// frozen.
///
/// **Nothing here is the price shown to the user.** `fallbackPriceText` is what the screen
/// draws only while StoreKit has not answered — see `SubscriptionOffer`. The App Store owns
/// the real figure, in the user's own currency and with their own tax in it, and a hard-coded
/// "€9.00" shown to someone billed in hryvnia is both wrong and a review finding.
enum SubscriptionPlan: String, CaseIterable, Sendable, Identifiable, Hashable {

    case monthly = "com.barosense.premium.monthly"
    case yearly = "com.barosense.premium.yearly"

    var id: String { rawValue }

    /// The order a paywall lists them in: yearly first, because it is the one with a saving to
    /// state and the one most users are better off on.
    ///
    /// Declared here rather than in the StoreKit adapter so the *same* order is used when
    /// StoreKit has answered and when it has not. Two orders would mean the cards visibly
    /// reshuffle under the user's thumb the moment prices arrive.
    static let inDisplayOrder: [SubscriptionPlan] = [.yearly, .monthly]

    /// How long one paid period runs. Used only to date a renewal the App Store has not
    /// given an expiry for, which is a state the sandbox produces and production should not.
    var periodDays: Int {
        switch self {
        case .monthly: 30
        case .yearly: 365
        }
    }

    /// The agreed list price, in euro, used for the saving arithmetic and as the last-resort
    /// label. Not a currency conversion and not a promise: see the note on the type.
    var fallbackPriceEUR: Decimal {
        switch self {
        case .monthly: 9.00
        case .yearly: 60.00
        }
    }

    /// What twelve months on this plan would cost, for the comparison the yearly card makes.
    private var annualisedPriceEUR: Decimal {
        switch self {
        case .monthly: fallbackPriceEUR * 12
        case .yearly: fallbackPriceEUR
        }
    }

    /// Percent saved against paying monthly for a year, rounded down, or `nil` when there is
    /// nothing to claim.
    ///
    /// Computed rather than written as a badge string. The two prices and the badge are then
    /// one fact instead of three that can drift — a "−40%" left behind after a price change is
    /// a misleading price claim, which is the kind App Review reads closely.
    ///
    /// Rounded **down** for the same reason: the badge may understate the saving, never
    /// overstate it.
    var savingPercentAgainstMonthly: Int? {
        let monthlyYear = SubscriptionPlan.monthly.annualisedPriceEUR
        guard monthlyYear > 0, annualisedPriceEUR < monthlyYear else { return nil }

        // Rounded through `NSDecimalRound` rather than by converting the raw quotient to
        // `Int`. `48/108` is a repeating decimal, and `NSDecimalNumber.intValue` on a value
        // carrying all 38 of `Decimal`'s significant digits answers **0** — so the obvious
        // spelling of this silently drops the badge instead of rounding it.
        var raw = (monthlyYear - annualisedPriceEUR) / monthlyYear * 100
        var floored = Decimal()
        NSDecimalRound(&floored, &raw, 0, .down)

        let percent = Int(truncating: floored as NSDecimalNumber)
        return percent > 0 ? percent : nil
    }
}

/// How long a new install may use the paid features before being asked.
///
/// **Seven days.** It is not an arbitrary marketing number here: `CLAUDE.md` constraint 5
/// requires the model to be useful on 3–7 days of history, so this is exactly the stretch over
/// which the user can see the thing they would be paying for actually working. A shorter trial
/// would ask for money before the forecast had enough history to be worth anything.
enum SubscriptionTrial {

    static let days = 7

    static var duration: TimeInterval { TimeInterval(days) * 24 * 3600 }
}

/// How long a cached purchase survives an App Store that answers "nothing".
///
/// **Three days.** The number is the balance between two failures, and both are real:
///
/// - Too short, and a subscriber whose account could not be read — signed out, a restored
///   device before its transactions have synced, a StoreKit outage — is locked out of what
///   they paid for. StoreKit cannot report that it failed to answer (`Transaction`
///   `currentEntitlements` yields nothing in that case exactly as it does for an account that
///   holds nothing), so time is the only thing left to tell the two apart.
/// - Too long, and a refunded or family-withdrawn subscription keeps the app open. That one is
///   bounded by this constant rather than by the cached expiry, which on the yearly plan would
///   be most of a year.
///
/// Three days covers a weekend away from a network and closes a revoked entitlement well
/// inside a single billing period. See `SubscriptionStatus.reconciled(with:asOf:)`.
enum SubscriptionGrace {

    static let days = 3

    static var duration: TimeInterval { TimeInterval(days) * 24 * 3600 }
}
