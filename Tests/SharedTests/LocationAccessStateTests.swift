import XCTest
@testable import Barosense

/// The four states of the location permission, and what each one lets the app do.
///
/// Acceptance criterion 7 in `.claude/context/pressure-forecast-spec.md` §5: all four are
/// exercised on a double, and none of them needs `CLLocationManager`.
final class LocationAccessStateTests: XCTestCase {

    /// Location services off device-wide. Nothing to ask for, so the row is inert and no
    /// route out of it exists — sending the user to Settings.app would land them on a page
    /// that cannot fix a device-wide switch.
    func testServicesOffIsInertAndOffersNothing() {
        let state = LocationAccessState.unavailable

        XCTAssertFalse(state.isGranted)
        XCTAssertFalse(state.isInteractive)
        XCTAssertFalse(state.canPresentPrompt)
        XCTAssertFalse(state.needsSystemSettings)
    }

    /// The one state in which a system prompt can still appear. Everything else has spent it.
    func testNotRequestedIsTheOnlyStateThatCanRaiseThePrompt() {
        let state = LocationAccessState.notRequested

        XCTAssertTrue(state.canPresentPrompt)
        XCTAssertTrue(state.isInteractive)
        XCTAssertFalse(state.isGranted)
        XCTAssertFalse(state.needsSystemSettings)
    }

    /// Acceptance criterion 9. iOS will not present the prompt a second time, so a refused
    /// row that offered the prompt again would be a control that does nothing.
    func testARefusalLeadsToSettingsAndNotToADeadPrompt() {
        let state = LocationAccessState.denied

        XCTAssertFalse(state.canPresentPrompt)
        XCTAssertTrue(state.needsSystemSettings)
        XCTAssertTrue(state.isInteractive)
        XCTAssertFalse(state.isGranted)
    }

    /// Acceptance criterion 8, at the state level. Reduced accuracy is what the app asks for
    /// — the epochs round to 0.1° and WeatherKit's grid is coarser again — so it is a working
    /// grant, not a partial one.
    func testReducedAccuracyIsAFullyWorkingGrant() {
        let reduced = LocationAccessState.granted(accuracy: .reduced)

        XCTAssertTrue(reduced.isGranted)
        XCTAssertTrue(reduced.isInteractive)
        XCTAssertFalse(reduced.canPresentPrompt)
        // Still routes to Settings, because that is where a grant is *changed* or withdrawn.
        XCTAssertTrue(reduced.needsSystemSettings)
    }

    /// Full accuracy is accepted and immediately rounded away. It is never asked for, and it
    /// must not read differently from reduced anywhere in the app.
    func testFullAccuracyBehavesExactlyLikeReduced() {
        let full = LocationAccessState.granted(accuracy: .full)
        let reduced = LocationAccessState.granted(accuracy: .reduced)

        XCTAssertEqual(full.isGranted, reduced.isGranted)
        XCTAssertEqual(full.isInteractive, reduced.isInteractive)
        XCTAssertEqual(full.canPresentPrompt, reduced.canPresentPrompt)
        XCTAssertEqual(full.needsSystemSettings, reduced.needsSystemSettings)
        // But they are not the same value — the row is allowed to know which it has.
        XCTAssertNotEqual(full, reduced)
    }

    // MARK: - Doubles that ship

    /// Acceptance criterion 10. The preview double reports the one actionable state and asks
    /// CoreLocation for nothing, so a canvas refresh cannot put a real system prompt on
    /// screen — the same contract `NoOpNotificationDeliverer` has.
    func testThePreviewReporterIsActionableAndAsksForNothing() async {
        let reporter = NoOpLocationAccessReporter()

        let state = await reporter.accessState()
        await reporter.requestAccess()

        XCTAssertEqual(state, .notRequested)
        XCTAssertTrue(state.canPresentPrompt)
    }

    func testTheUnavailableReporterNeverReportsAGrant() async {
        let state = await UnavailableLocationAccessReporter().accessState()

        XCTAssertEqual(state, .unavailable)
    }

    /// The stub the other suites configure. A prompt is only ever raised by an explicit call,
    /// never as a side effect of reading the state.
    func testReadingTheStateNeverRaisesAPrompt() async {
        let reporter = StubLocationAccessReporter(state: .notRequested)

        _ = await reporter.accessState()
        _ = await reporter.accessState()

        XCTAssertEqual(reporter.requestCount, 0)
    }
}
