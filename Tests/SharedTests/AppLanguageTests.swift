import XCTest
@testable import Barosense

/// Which language the app renders in, given what the user picked and what the device asks
/// for. Pure resolution — no bundle, no `Locale.preferredLanguages`.
final class AppLanguageResolutionTests: XCTestCase {

    func testAPinnedLanguageIgnoresTheDevice() {
        let selection = LanguageSelection.fixed(.english)

        XCTAssertEqual(selection.resolved(preferredLanguages: ["uk-UA", "en-GB"]), .english)
    }

    func testSystemTakesTheFirstShippedLanguageInTheDevicesOrder() {
        let selection = LanguageSelection.system

        XCTAssertEqual(selection.resolved(preferredLanguages: ["uk-UA", "en-GB"]), .ukrainian)
        XCTAssertEqual(selection.resolved(preferredLanguages: ["en-GB", "uk-UA"]), .english)
    }

    /// iOS hands back region-tagged identifiers. Matching whole strings would miss every
    /// one of them and silently drop a Ukrainian device to the base language.
    func testARegionTaggedIdentifierStillMatches() {
        XCTAssertEqual(AppLanguage.firstSupported(in: ["uk-UA"]), .ukrainian)
        XCTAssertEqual(AppLanguage.firstSupported(in: ["en-US"]), .english)
    }

    func testSystemSkipsLanguagesTheAppDoesNotShip() {
        let selection = LanguageSelection.system

        XCTAssertEqual(selection.resolved(preferredLanguages: ["de-DE", "fr-FR", "uk"]), .ukrainian)
    }

    /// The base language is the fallback, because every `LocalizedStringKey` literal in the
    /// source is already English — there is no state in which it can be missing.
    func testAnUnsupportedDeviceLanguageFallsBackToTheBaseLanguage() {
        XCTAssertEqual(LanguageSelection.system.resolved(preferredLanguages: ["de-DE"]), .english)
        XCTAssertEqual(LanguageSelection.system.resolved(preferredLanguages: []), .english)
    }

    func testTheLocaleCarriesNoRegion() {
        // The user picked a language, not a country. A region here would also change date
        // order and number separators for someone who only wanted the words to change.
        XCTAssertNil(AppLanguage.ukrainian.locale.region)
        XCTAssertEqual(AppLanguage.ukrainian.locale.identifier, "uk")
    }
}

/// The stored preference, including the `AppleLanguages` override iOS itself reads.
final class LanguagePreferenceStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "barosense.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTheDefaultIsToFollowTheSystem() {
        let store = UserDefaultsLanguagePreferenceStore(defaults: defaults)

        XCTAssertEqual(store.selection(), .system)
    }

    func testAPinnedLanguageRoundTrips() {
        let store = UserDefaultsLanguagePreferenceStore(defaults: defaults)

        store.setSelection(.fixed(.ukrainian))

        XCTAssertEqual(store.selection(), .fixed(.ukrainian))
    }

    /// The second key is what iOS reads for system-supplied UI at the next launch. Without
    /// it the app would switch language and the sheets around it would not.
    func testPinningAlsoWritesAppleLanguages() {
        let store = UserDefaultsLanguagePreferenceStore(defaults: defaults)

        store.setSelection(.fixed(.ukrainian))

        XCTAssertEqual(appleLanguagesOverride(), ["uk"])
    }

    /// Going back to `.system` has to remove the override, not rewrite it with today's
    /// resolved language — otherwise the app freezes on that language and stops following
    /// the device.
    func testGoingBackToSystemClearsTheOverride() {
        let store = UserDefaultsLanguagePreferenceStore(defaults: defaults)
        store.setSelection(.fixed(.english))

        store.setSelection(.system)

        XCTAssertEqual(store.selection(), .system)
        XCTAssertNil(appleLanguagesOverride())
    }

    /// The app's *own* `AppleLanguages` entry, read out of the domain rather than through
    /// `stringArray(forKey:)`.
    ///
    /// A `UserDefaults` instance searches the global domain as well as its own, so once the
    /// override is removed a plain read returns the device's language list — which is the
    /// behaviour production wants and exactly what makes it useless as an assertion here.
    private func appleLanguagesOverride() -> [String]? {
        defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String]
    }

    /// A value written by a build that shipped a language this one does not.
    func testAnUnknownStoredLanguageReadsAsSystem() {
        defaults.set("de", forKey: "barosense.settings.language")

        XCTAssertEqual(UserDefaultsLanguagePreferenceStore(defaults: defaults).selection(), .system)
    }
}
