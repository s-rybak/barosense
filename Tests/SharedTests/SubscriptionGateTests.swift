import XCTest
@testable import Barosense

/// The paywall's arithmetic: when the free week ends, what a purchase does to it, and when the
/// app is allowed to raise the offer by itself.
///
/// Every case walks a synthetic clock rather than sleeping. That is the whole reason
/// `SubscriptionStatus` takes `asOf:` everywhere instead of reading `Date()` inside — a trial
/// boundary is not something a test may wait seven days for.
final class SubscriptionGateTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    private func days(_ count: Double) -> TimeInterval { count * 24 * 3600 }

    // MARK: - Trial

    func testAFreshInstallIsOpenForSevenDays() {
        let status = SubscriptionStatus(trialStartedAt: start)

        XCTAssertTrue(status.isActive(asOf: start))
        XCTAssertTrue(status.isActive(asOf: start.addingTimeInterval(days(6.9))))
        XCTAssertFalse(status.isActive(asOf: start.addingTimeInterval(days(7))))
        XCTAssertFalse(status.isActive(asOf: start.addingTimeInterval(days(8))))
    }

    func testAnInstallWithNoTrialYetIsNeitherActiveNorExpired() {
        // The two are different facts. An install whose trial has not begun must not be shown
        // an expiry message about a stretch it never had.
        let status = SubscriptionStatus()

        XCTAssertFalse(status.isActive(asOf: start))
        XCTAssertFalse(status.hasTrialExpired(asOf: start))
        XCTAssertNil(status.activeUntil(asOf: start))
    }

    func testTheDaysRemainingRoundUpSoTheLastOneIsStillCounted() {
        let status = SubscriptionStatus(trialStartedAt: start)

        XCTAssertEqual(status.daysRemaining(asOf: start), 7)
        // Six and a half days in: half a day left, which the user is told is one.
        XCTAssertEqual(status.daysRemaining(asOf: start.addingTimeInterval(days(6.5))), 1)
        XCTAssertNil(status.daysRemaining(asOf: start.addingTimeInterval(days(9))))
    }

    // MARK: - Purchase

    func testAPurchaseCarriesTheInstallPastTheTrial() {
        let status = SubscriptionStatus(trialStartedAt: start,
                                        plan: .monthly,
                                        purchaseExpiresAt: start.addingTimeInterval(days(30)))

        XCTAssertTrue(status.isActive(asOf: start.addingTimeInterval(days(20))))
        XCTAssertFalse(status.hasTrialExpired(asOf: start.addingTimeInterval(days(20))))
        XCTAssertFalse(status.isActive(asOf: start.addingTimeInterval(days(31))))
    }

    func testAPurchaseMadeDuringTheTrialIsWhatTheCardReports() {
        // Someone who buys on day two is a subscriber for the rest of that week, not a
        // trialist — the card has to print the renewal date, not a trial about to end under
        // a paid subscription.
        let bought = start.addingTimeInterval(days(2))
        let renews = bought.addingTimeInterval(days(365))
        let status = SubscriptionStatus(trialStartedAt: start,
                                        plan: .yearly,
                                        purchaseExpiresAt: renews)

        XCTAssertEqual(status.source(asOf: bought), .purchase)
        XCTAssertEqual(status.activeUntil(asOf: bought), renews)
    }

    func testALapsedPurchaseDoesNotReviveAnAlreadySpentTrial() {
        let status = SubscriptionStatus(trialStartedAt: start,
                                        plan: .monthly,
                                        purchaseExpiresAt: start.addingTimeInterval(days(30)))
        let after = start.addingTimeInterval(days(40))

        XCTAssertNil(status.source(asOf: after))
        XCTAssertTrue(status.hasTrialExpired(asOf: after))
    }

    // MARK: - Feature gate

    func testEveryGatedFeatureOpensAndClosesTogether() {
        // One purchase, so a per-feature table would be an abstraction with no second case.
        let status = SubscriptionStatus(trialStartedAt: start)
        let inside = start.addingTimeInterval(days(1))
        let outside = start.addingTimeInterval(days(10))

        for feature in PremiumFeature.allCases {
            XCTAssertTrue(SubscriptionGate.isUnlocked(feature, status: status, asOf: inside))
            XCTAssertFalse(SubscriptionGate.isUnlocked(feature, status: status, asOf: outside))
        }
    }

    // MARK: - Offering

    func testTheOfferIsMadeOnceTheTrialEndsAndNotBefore() {
        let status = SubscriptionStatus(trialStartedAt: start)

        XCTAssertFalse(SubscriptionGate.shouldOfferPaywall(status: status, asOf: start))
        XCTAssertTrue(SubscriptionGate.shouldOfferPaywall(
            status: status, asOf: start.addingTimeInterval(days(7))))
    }

    func testTheOfferIsNotRepeatedOnceItHasBeenMade() {
        // A paywall that reappears at every launch is nagging, and nagging is its own review
        // finding.
        let expiry = start.addingTimeInterval(days(7))
        let status = SubscriptionStatus(trialStartedAt: start,
                                        lastOfferedAt: expiry.addingTimeInterval(60))

        XCTAssertFalse(SubscriptionGate.shouldOfferPaywall(
            status: status, asOf: expiry.addingTimeInterval(days(3))))
    }

    func testAVisitToTheSettingsScreenDuringTheTrialDoesNotSpendTheOffer() {
        // The stamp is compared against the *end* of the trial, so an offer looked at on day
        // two is not the one the expiry is owed.
        let status = SubscriptionStatus(trialStartedAt: start,
                                        lastOfferedAt: start.addingTimeInterval(days(2)))

        XCTAssertTrue(SubscriptionGate.shouldOfferPaywall(
            status: status, asOf: start.addingTimeInterval(days(7))))
    }

    func testNothingIsOfferedWhileASubscriptionIsRunning() {
        let status = SubscriptionStatus(trialStartedAt: start,
                                        plan: .yearly,
                                        purchaseExpiresAt: start.addingTimeInterval(days(365)))

        XCTAssertFalse(SubscriptionGate.shouldOfferPaywall(
            status: status, asOf: start.addingTimeInterval(days(30))))
    }

    // MARK: - Plans

    func testTheYearlySavingIsComputedFromTheTwoPricesAndRoundedDown() {
        // €9/month is €108 a year against €60, which is 44.4% — stated as 44 so the badge can
        // only ever understate the saving.
        XCTAssertEqual(SubscriptionPlan.yearly.savingPercentAgainstMonthly, 44)
        XCTAssertNil(SubscriptionPlan.monthly.savingPercentAgainstMonthly)
    }

    func testEveryPlanAppearsExactlyOnceInTheDisplayOrder() {
        // The paywall draws this list when StoreKit has answered *and* when it has not. A plan
        // missing from it would be unsellable; a duplicate would draw two cards for one
        // product.
        XCTAssertEqual(Set(SubscriptionPlan.inDisplayOrder), Set(SubscriptionPlan.allCases))
        XCTAssertEqual(SubscriptionPlan.inDisplayOrder.count, SubscriptionPlan.allCases.count)
        XCTAssertEqual(SubscriptionPlan.inDisplayOrder.first, .yearly)
    }

    func testTheProductIdentifiersAreDistinct() {
        // They are storage and protocol at once — the raw value is written into the durable
        // row *and* is what the App Store is asked for.
        XCTAssertEqual(Set(SubscriptionPlan.allCases.map(\.rawValue)).count,
                       SubscriptionPlan.allCases.count)
    }
}
