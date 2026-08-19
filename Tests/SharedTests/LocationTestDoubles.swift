import Foundation
@testable import Barosense

/// Location doubles shared by more than one test file.
///
/// Internal rather than `private`, unlike most doubles here, because the location permission
/// is read from two places that are tested separately — the settings row and the epoch
/// recorder — and two copies of the same stub would drift.
///
/// None of them touches `CLLocationManager` or `CLGeocoder`, which is the point: acceptance
/// criteria 1 and 7 in `.claude/context/pressure-forecast-spec.md` §5 both say the state
/// machine has to be checkable without CoreLocation on the other end.
final class StubLocationAccessReporter: LocationAccessReporting, @unchecked Sendable {

    /// A lock rather than an actor, matching `StubHealthAccessReporter`: the protocol is
    /// `Sendable` and non-isolated, and a double that must be awaited to configure is harder
    /// to read than one guarded lock.
    private let lock = NSLock()
    private var _state: LocationAccessState
    private var _requestCount = 0

    init(state: LocationAccessState) {
        _state = state
    }

    var state: LocationAccessState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    /// How many times a system prompt would have been raised. The number the preview
    /// double has to keep at zero.
    var requestCount: Int { lock.withLock { _requestCount } }

    func accessState() async -> LocationAccessState { state }

    func requestAccess() async {
        lock.withLock { _requestCount += 1 }
    }
}

/// Hands back a scripted sequence of fixes, one per call, repeating the last one forever.
final class StubLocationFixProvider: LocationFixProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var fixes: [LocationFix?]
    private var index = 0

    init(_ fixes: [LocationFix?]) {
        self.fixes = fixes
    }

    convenience init(coordinate: GeoCoordinate, takenAt: Date) {
        self.init([LocationFix(coordinate: coordinate, takenAt: takenAt)])
    }

    func currentFix() async -> LocationFix? {
        lock.withLock {
            guard !fixes.isEmpty else { return nil }
            let fix = fixes[min(index, fixes.count - 1)]
            index += 1
            return fix
        }
    }
}

/// Names every coordinate the same, and counts how often it was asked.
///
/// The counter is the test: Apple's geocoder is throttled with unpublished limits, so "at
/// most one call per epoch" is a shipped constraint rather than an optimisation.
final class CountingPlaceNamer: PlaceNaming, @unchecked Sendable {

    private let lock = NSLock()
    private var _callCount = 0
    private let name: PlaceName?

    init(name: PlaceName? = PlaceName(locality: "Kyiv",
                                      administrativeArea: "Kyiv",
                                      country: "Ukraine")) {
        self.name = name
    }

    var callCount: Int { lock.withLock { _callCount } }

    func placeName(for coordinate: GeoCoordinate) async -> PlaceName? {
        lock.withLock { _callCount += 1 }
        return name
    }
}
