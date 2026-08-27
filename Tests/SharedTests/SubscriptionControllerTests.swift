import XCTest
@testable import Barosense

/// The controller that holds the entitlement: what it does on first launch, how it folds the
/// App Store's answer into the stored row, and what it writes when a purchase lands.
///
/// Runs against a fake purchaser. StoreKit itself cannot be driven from a unit test — it needs
/// a signed build, a configured App Store Connect product and a sandbox account — which is
/// exactly why `SubscriptionPurchasing` exists.
@MainActor
final class SubscriptionControllerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    private func days(_ count: Double) -> TimeInterval { count * 24 * 3600 }

    // MARK: - First launch

    func testAFreshInstallStartsItsTrialAndWritesIt() async throws {
        let store = InMemorySubscriptionStatusStore()
        let controller = makeController(store: store)

        await controller.load()

        XCTAssertEqual(controller.status.trialStartedAt, start)
        XCTAssertTrue(controller.isUnlocked(.report))
        // Written, not just held: a trial that restarted on every launch would never end.
        XCTAssertEqual(try store.status().trialStartedAt, start)
    }

    func testASecondLaunchDoesNotRestartTheTrial() async {
        let store = InMemorySubscriptionStatusStore(
            SubscriptionStatus(trialStartedAt: start.addingTimeInterval(-days(30)))
        )
        let controller = makeController(store: store)

        await controller.load()

        XCTAssertEqual(controller.status.trialStartedAt, start.addingTimeInterval(-days(30)))
        XCTAssertFalse(controller.isUnlocked(.report))
        XCTAssertTrue(controller.shouldOfferPaywall)
    }

    // MARK: - Reconciling

    func testTheAppStoreAnswerOverwritesTheStoredRow() async throws {
        // One direction only: the App Store is the authority on a purchase, and the row is a
        // cache of its last answer.
        let store = InMemorySubscriptionStatusStore(SubscriptionStatus(trialStartedAt: start))
        let renews = start.addingTimeInterval(days(365))
        let purchasing = FakePurchaser(entitlement: PurchasedEntitlement(plan: .yearly,
                                                                         expiresAt: renews))
        let controller = makeController(store: store, purchasing: purchasing)

        await controller.load()

        XCTAssertEqual(controller.status.plan, .yearly)
        XCTAssertEqual(controller.status.purchaseExpiresAt, renews)
        XCTAssertEqual(try store.status().plan, .yearly)
    }

    func testAnEmptyAnswerDoesNotImmediatelyCloseALivePurchase() async {
        // The failure this guards against: StoreKit cannot say "I could not ask" — a signed-out
        // Apple Account answers exactly like an account that holds nothing — so wiping the row
        // on the first empty answer locks a paying subscriber out of what they bought.
        let store = InMemorySubscriptionStatusStore(
            SubscriptionStatus(trialStartedAt: start.addingTimeInterval(-days(30)),
                               plan: .monthly,
                               purchaseExpiresAt: start.addingTimeInterval(days(30)),
                               purchaseConfirmedAt: start)
        )
        let controller = makeController(store: store,
                                        purchasing: FakePurchaser(entitlement: nil),
                                        at: start.addingTimeInterval(days(1)))

        await controller.load()

        XCTAssertEqual(controller.status.plan, .monthly)
        XCTAssertTrue(controller.isUnlocked(.report))
    }

    func testALivePurchaseIsClosedOnceTheGraceWindowRunsOut() async {
        // The other half of the same rule. A refund or a family withdrawal also answers empty,
        // and the cached expiry is a year away on the yearly plan — so the hold has to end.
        let store = InMemorySubscriptionStatusStore(
            SubscriptionStatus(trialStartedAt: start.addingTimeInterval(-days(30)),
                               plan: .yearly,
                               purchaseExpiresAt: start.addingTimeInterval(days(300)),
                               purchaseConfirmedAt: start)
        )
        let controller = makeController(
            store: store,
            purchasing: FakePurchaser(entitlement: nil),
            at: start.addingTimeInterval(SubscriptionGrace.duration + 1)
        )

        await controller.load()

        XCTAssertNil(controller.status.plan)
        XCTAssertNil(controller.status.purchaseExpiresAt)
        XCTAssertFalse(controller.isUnlocked(.report))
    }

    func testAPurchaseThatHasRunOutOnItsOwnDateIsClearedWithoutWaiting() async {
        // No entitlement left to protect, so the empty answer is simply true and the grace
        // window has nothing to do.
        let store = InMemorySubscriptionStatusStore(
            SubscriptionStatus(trialStartedAt: start.addingTimeInterval(-days(30)),
                               plan: .monthly,
                               purchaseExpiresAt: start.addingTimeInterval(-days(1)),
                               purchaseConfirmedAt: start.addingTimeInterval(-days(31)))
        )
        let controller = makeController(store: store, purchasing: FakePurchaser(entitlement: nil))

        await controller.load()

        XCTAssertNil(controller.status.plan)
        XCTAssertNil(controller.status.purchaseExpiresAt)
    }

    func testARowWrittenBeforeTheStampExistedStartsItsGraceNow() async {
        // Lightweight migration: `purchaseConfirmedAt` reads back `nil` on an existing install.
        // Stamping it on the first empty answer is what stops the window restarting on every
        // activation and never closing.
        let store = InMemorySubscriptionStatusStore(
            SubscriptionStatus(trialStartedAt: start.addingTimeInterval(-days(30)),
                               plan: .monthly,
                               purchaseExpiresAt: start.addingTimeInterval(days(30)))
        )
        let controller = makeController(store: store, purchasing: FakePurchaser(entitlement: nil))

        await controller.load()

        XCTAssertEqual(controller.status.purchaseConfirmedAt, start)
        XCTAssertEqual(try? store.status().purchaseConfirmedAt, start)
    }

    func testATransactionDeliveredByTheAppStoreIsReconciled() async {
        // A renewal, a purchase made on another device, or an Ask to Buy approved later. Without
        // this loop none of them is noticed until the next foreground activation — and none of
        // them is ever finished, so the App Store redelivers them for ever.
        let purchaser = FakePurchaser(entitlement: nil)
        let controller = makeController(
            store: InMemorySubscriptionStatusStore(
                SubscriptionStatus(trialStartedAt: start.addingTimeInterval(-days(30)))
            ),
            purchasing: purchaser
        )

        await controller.load()
        controller.observeTransactions()
        XCTAssertFalse(controller.isUnlocked(.report))

        purchaser.entitlement = PurchasedEntitlement(plan: .yearly,
                                                     expiresAt: start.addingTimeInterval(days(365)))
        purchaser.deliverTransaction()

        await waitUntil { controller.isUnlocked(.report) }
        XCTAssertEqual(controller.status.plan, .yearly)
    }

    func testReconcileWritesNothingWhenNothingHasChanged() async {
        // Called on every foreground activation, so a write per activation would be a store
        // hit for no reason.
        let store = CountingSubscriptionStore(SubscriptionStatus(trialStartedAt: start))
        let controller = makeController(store: store)
        await controller.load()
        let writesAfterLoad = store.saveCount

        await controller.reconcile()

        XCTAssertEqual(store.saveCount, writesAfterLoad)
    }

    // MARK: - Buying

    func testAPurchaseUnlocksEverythingAndIsPersisted() async throws {
        let store = InMemorySubscriptionStatusStore(
            SubscriptionStatus(trialStartedAt: start.addingTimeInterval(-days(30)))
        )
        let purchasing = FakePurchaser(entitlement: nil)
        let controller = makeController(store: store, purchasing: purchasing)
        await controller.load()
        XCTAssertFalse(controller.isUnlocked(.insights))

        purchasing.entitlement = PurchasedEntitlement(plan: .monthly,
                                                      expiresAt: start.addingTimeInterval(days(30)))
        await controller.purchase(.monthly)

        XCTAssertTrue(controller.isUnlocked(.insights))
        XCTAssertEqual(controller.source, .purchase)
        XCTAssertEqual(try store.status().plan, .monthly)
    }

    func testACancelledPurchaseSaysNothing() async {
        // The user answered the App Store's own sheet. An error message over a decision they
        // made deliberately reads as the app arguing with them.
        let controller = makeController(purchasing: FakePurchaser(entitlement: nil))
        await controller.load()

        await controller.purchase(.yearly)

        XCTAssertNil(controller.failure)
        XCTAssertNil(controller.status.plan)
    }

    func testAFailedPurchaseIsReported() async {
        let purchasing = FakePurchaser(entitlement: nil)
        purchasing.error = SubscriptionError.productUnavailable
        let controller = makeController(purchasing: purchasing)
        await controller.load()

        await controller.purchase(.yearly)

        XCTAssertEqual(controller.failure, .purchaseFailed)
    }

    func testARestoreThatFindsNothingSaysSo() async {
        // Unlike a cancelled purchase: the user asked a question, and silence is not an answer
        // to it.
        let controller = makeController(purchasing: FakePurchaser(entitlement: nil))
        await controller.load()

        await controller.restore()

        XCTAssertEqual(controller.failure, .nothingToRestore)
    }

    func testARestoreBringsBackAPreviousSubscription() async {
        let renews = start.addingTimeInterval(days(200))
        let purchasing = FakePurchaser(entitlement: nil)
        let controller = makeController(
            store: InMemorySubscriptionStatusStore(
                SubscriptionStatus(trialStartedAt: start.addingTimeInterval(-days(30)))
            ),
            purchasing: purchasing
        )
        await controller.load()

        purchasing.restored = PurchasedEntitlement(plan: .yearly, expiresAt: renews)
        await controller.restore()

        XCTAssertEqual(controller.source, .purchase)
        XCTAssertEqual(controller.activeUntil, renews)
        XCTAssertNil(controller.failure)
    }

    // MARK: - Offer bookkeeping

    func testStampingTheOfferStopsItBeingMadeAgain() async {
        let controller = makeController(
            store: InMemorySubscriptionStatusStore(
                SubscriptionStatus(trialStartedAt: start.addingTimeInterval(-days(30)))
            )
        )
        await controller.load()
        XCTAssertTrue(controller.shouldOfferPaywall)

        await controller.recordPaywallOffered()

        XCTAssertFalse(controller.shouldOfferPaywall)
    }

    // MARK: - Helpers

    /// Waits for the transaction loop to catch up.
    ///
    /// Polled rather than awaited: the loop runs on its own task, so there is no single
    /// suspension point in the test that means "it has finished reconciling".
    private func waitUntil(timeout: TimeInterval = 2,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition still false after \(timeout)s", file: file, line: line)
    }

    private func makeController(
        store: any SubscriptionStatusStore = InMemorySubscriptionStatusStore(),
        purchasing: any SubscriptionPurchasing = NoOpSubscriptionPurchaser(),
        at instant: Date? = nil
    ) -> SubscriptionController {
        let clock = instant ?? start
        return SubscriptionController(store: store, purchasing: purchasing, now: { clock })
    }
}

// MARK: - Doubles

/// A purchaser whose answers are set by the test. Nothing here reaches StoreKit.
private final class FakePurchaser: SubscriptionPurchasing, @unchecked Sendable {

    /// What `currentEntitlement()` reports, and what a successful `purchase` returns.
    var entitlement: PurchasedEntitlement?

    /// What `restore()` finds, if anything. Separate from `entitlement` so a restore can bring
    /// back something the current entitlement did not have.
    var restored: PurchasedEntitlement?

    /// Thrown by `purchase` and `restore` when set.
    var error: (any Error)?

    init(entitlement: PurchasedEntitlement?) {
        self.entitlement = entitlement
    }

    /// Lets a test push a transaction the App Store "delivered" on its own.
    private let updates = AsyncStream<Void>.makeStream()

    func offers() async -> [SubscriptionOffer] { [] }

    func transactionUpdates() -> AsyncStream<Void> { updates.stream }

    func deliverTransaction() { updates.continuation.yield(()) }

    func purchase(_ plan: SubscriptionPlan) async throws -> PurchasedEntitlement? {
        if let error { throw error }
        return entitlement
    }

    func currentEntitlement() async -> PurchasedEntitlement? { entitlement }

    func restore() async throws -> PurchasedEntitlement? {
        if let error { throw error }
        entitlement = restored
        return restored
    }
}

/// Counts writes. How often the store is *asked* to save is the assertion, and inspecting its
/// contents cannot show that.
private final class CountingSubscriptionStore: SubscriptionStatusStore, @unchecked Sendable {

    private(set) var saveCount = 0
    private var stored: SubscriptionStatus

    init(_ status: SubscriptionStatus) {
        stored = status
    }

    func status() async throws -> SubscriptionStatus { stored }

    func save(_ status: SubscriptionStatus) async throws {
        saveCount += 1
        stored = status
    }
}
