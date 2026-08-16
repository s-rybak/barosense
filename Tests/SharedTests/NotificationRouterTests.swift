import XCTest
@testable import Barosense

/// Where a tapped notification sends the user, and what happens to a tap that arrives before
/// there is anything to send them to.
@MainActor
final class NotificationRouterTests: XCTestCase {

    // MARK: - Reading the payload

    /// The reminder asks the user to check in, so the tap opens the check-in. Anything else —
    /// opening on the last tab and leaving them to find the button — wastes the notification.
    func testTheReminderRoutesToTheCheckIn() {
        XCTAssertEqual(NotificationRoute(kindRawValue: NotificationKind.checkInReminder.rawValue),
                       .checkIn)
    }

    /// A request scheduled by a newer build and tapped after a downgrade. The app opens where the
    /// user left it, which is the one outcome that is never wrong.
    func testAnUnknownKindRoutesNowhere() {
        XCTAssertNil(NotificationRoute(kindRawValue: "forecastWarning"))
        XCTAssertNil(NotificationRoute(kindRawValue: ""))
    }

    /// The raw value is the payload format, and a payload already sitting in a scheduled request
    /// cannot be migrated. Renaming the case would leave a week of notifications tapping through
    /// to nothing, so the string is pinned here as well as at the storage layer.
    func testTheKindTravelsAsItsRawValue() {
        XCTAssertEqual(NotificationKind.checkInReminder.rawValue, "checkInReminder")
    }

    // MARK: - Holding the route

    /// A tap can be delivered while the window is still being built — a cold launch from the
    /// lock screen does exactly that — so a route recorded before anyone is watching has to
    /// survive until someone is.
    func testARouteIsHeldUntilItIsTaken() {
        let router = NotificationRouter()
        XCTAssertNil(router.pending)

        router.request(.checkIn)

        XCTAssertEqual(router.pending, .checkIn)
    }

    /// Cleared by whoever acted on it, so a later scene activation does not reopen the sheet over
    /// a check-in the user has already written.
    func testTakingARouteClearsIt() {
        let router = NotificationRouter()
        router.request(.checkIn)

        router.clear()

        XCTAssertNil(router.pending)
    }
}
