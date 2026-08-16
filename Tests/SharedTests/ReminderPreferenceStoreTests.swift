import XCTest
@testable import Barosense

/// The reminder switch's stored value — and the one thing about it that is easy to get wrong.
final class ReminderPreferenceStoreTests: XCTestCase {

    /// A suite of its own per test, removed afterwards, so nothing here can read or leave
    /// behind the simulator's real preference.
    private func makeDefaults(function: String = #function) throws -> UserDefaults {
        let name = "barosense.tests.\(function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        // The suite name is captured, not the instance: `UserDefaults` is not `Sendable`, and
        // removing the domain works through any instance rather than only the one that wrote it.
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }

        return defaults
    }

    /// The whole reason this store does not use `bool(forKey:)`. iOS gates the reminder behind
    /// a permission prompt already; a fresh install that reported `false` here would need the
    /// user to say yes twice to hear from the app once — and the second switch is one nobody
    /// would think to look for.
    func testAFreshInstallWantsTheReminder() throws {
        let store = UserDefaultsReminderPreferenceStore(defaults: try makeDefaults())

        XCTAssertTrue(store.isCheckInReminderEnabled())
    }

    func testTurningItOffIsRemembered() throws {
        let defaults = try makeDefaults()
        let store = UserDefaultsReminderPreferenceStore(defaults: defaults)

        store.setCheckInReminderEnabled(false)

        XCTAssertFalse(store.isCheckInReminderEnabled())
        // Read back through a second instance: the value has to be on disk, not in the struct.
        XCTAssertFalse(UserDefaultsReminderPreferenceStore(defaults: defaults)
            .isCheckInReminderEnabled())
    }

    /// Turning it back on writes `true` rather than removing the key. Either would read the
    /// same today, but only one of them survives the default being changed later.
    func testTurningItBackOnIsRemembered() throws {
        let store = UserDefaultsReminderPreferenceStore(defaults: try makeDefaults())

        store.setCheckInReminderEnabled(false)
        store.setCheckInReminderEnabled(true)

        XCTAssertTrue(store.isCheckInReminderEnabled())
    }

    func testTheInMemoryStoreBehavesTheSameWay() {
        let store = InMemoryReminderPreferenceStore()
        XCTAssertTrue(store.isCheckInReminderEnabled())

        store.setCheckInReminderEnabled(false)

        XCTAssertFalse(store.isCheckInReminderEnabled())
    }
}
