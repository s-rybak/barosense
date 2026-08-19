import CoreLocation
import Foundation

/// The one place `CLLocationManager` is touched.
///
/// A `@MainActor` singleton, for two reasons that are both CoreLocation's rather than this
/// app's. `CLLocationManager` is documented as belonging on a thread with an active run loop
/// and delivers its delegate callbacks there, and it must stay alive for the whole of a
/// request — a manager created inside a function is deallocated before the delegate fires,
/// which is the classic way to get a location API that never answers.
///
/// The callback API is wrapped **once**, here, in continuations. Nothing above this file sees
/// a delegate (`.claude/skills/swift_conventions/SKILL.md`).
///
/// ## Battery
///
/// No new wake source. `requestLocation()` is a one-shot: the radio runs until a fix arrives
/// or the request fails, and never longer. There is no `startUpdatingLocation`, no significant
/// location change monitoring, no `CLBackgroundActivitySession`, and no `location` background
/// mode in the Info.plist — so nothing here can keep the app resident.
@MainActor
final class CoreLocationService: NSObject {

    static let shared = CoreLocationService()

    private let manager = CLLocationManager()

    /// Callers waiting on `requestWhenInUseAuthorization()` to be answered.
    ///
    /// A list rather than one slot: the Settings row and the explanatory screen can both be on
    /// screen in the same instant, and dropping the earlier continuation would leak a task
    /// that never resumes.
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Callers waiting on the current one-shot fix. Coalesced — `requestLocation()` is only
    /// issued when this list goes from empty to non-empty, so ten simultaneous asks cost one
    /// radio start.
    private var fixWaiters: [CheckedContinuation<LocationFix?, Never>] = []

    private override init() {
        super.init()
        manager.delegate = self
        // Reduced is what the feature needs and all it asks for. `NSLocationDefaultAccuracyReduced`
        // in the Info.plist already makes it the default the user is asked for; this makes the
        // desired accuracy match, so the manager does not spend GPS time refining a fix that is
        // about to be rounded to 0.1°.
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    // MARK: - Authorisation

    /// Current authorisation, translated into the four states the row and the scheduler branch
    /// on.
    ///
    /// `locationServicesEnabled()` is deliberately called **off** the main actor. Apple warns
    /// it can block while the location daemon starts, and this is read on every appearance of
    /// the Settings screen; a detached read costs one hop and cannot stutter the screen it is
    /// drawing. Whether it actually blocks on iOS 26 is question 7 in
    /// `.claude/context/pressure-forecast-spec.md` §7.2 — this is the answer that is safe
    /// either way.
    func accessState() async -> LocationAccessState {
        let servicesEnabled = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
        guard servicesEnabled else { return .unavailable }

        switch manager.authorizationStatus {
        case .notDetermined:
            return .notRequested
        case .denied, .restricted:
            return .denied
        case .authorizedWhenInUse, .authorizedAlways:
            return .granted(accuracy: manager.accuracyAuthorization == .fullAccuracy
                            ? .full
                            : .reduced)
        @unknown default:
            // A status this build does not know about is not evidence of a grant, and the one
            // safe reading of "unknown" is the state whose action is a trip to Settings.
            return .denied
        }
    }

    /// Raises the system prompt and returns once the user has answered.
    ///
    /// **When-in-use only.** `requestAlwaysAuthorization` is never called: nothing in this
    /// feature runs in the background, and asking for a permission with no consumer is the
    /// surgical-permissions rule broken on a different framework.
    ///
    /// Returns immediately in every state but `.notDetermined` — iOS answers a repeat request
    /// from its own record without showing anything, so awaiting the delegate there would hang
    /// on a callback that arrives only because the status did not change.
    func requestAccess() async {
        guard manager.authorizationStatus == .notDetermined else { return }

        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - Fixes

    /// One fix, or `nil`.
    ///
    /// Never asks without a grant: `requestLocation()` on an unauthorised manager reports a
    /// failure through the delegate after powering nothing useful, and checking first keeps a
    /// refusal genuinely free.
    func currentFix() async -> LocationFix? {
        guard await accessState().isGranted else { return nil }

        return await withCheckedContinuation { continuation in
            fixWaiters.append(continuation)
            // Only the first waiter starts the radio. `requestLocation` delivers exactly one
            // fix (or one failure) per call, so a second call here would be a second radio
            // start whose answer nobody is left waiting for.
            if fixWaiters.count == 1 {
                manager.requestLocation()
            }
        }
    }

    private func finishFix(_ fix: LocationFix?) {
        let waiters = fixWaiters
        fixWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: fix)
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension CoreLocationService: CLLocationManagerDelegate {

    /// Fires on the answer to the prompt **and** whenever the user changes the grant in
    /// Settings while the app is backgrounded.
    ///
    /// The second case is why the Settings row needs no polling, and — more consequentially —
    /// why a revoked grant stops costing forecast slots: `WeatherRequestBudget` reads the
    /// access state before it spends one, so a revocation simply stops the requests instead of
    /// burning the day's allowance on calls that cannot run.
    ///
    /// `MainActor.assumeIsolated` rather than a detached hop onto the main actor: CoreLocation
    /// delivers its callbacks on the run loop the manager was created on, and that is this
    /// actor's. Asserting the isolation the callback already has keeps the resume synchronous;
    /// scheduling it would let two callbacks arrive in one order and resume their waiters in
    /// another.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            let waiters = authorizationWaiters
            authorizationWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        // The newest fix. `requestLocation` delivers one, but the array form is the contract
        // and taking the last of it is what stays right if that ever changes.
        let newest = locations.last
        let fix = newest.map { location in
            LocationFix(
                coordinate: GeoCoordinate(latitude: location.coordinate.latitude,
                                          longitude: location.coordinate.longitude),
                // A negative vertical accuracy means the altitude is not valid — CoreLocation's
                // own signal for "this field is filler". Under reduced accuracy, which is the
                // shipped default, that is the usual answer.
                altitudeMetres: location.verticalAccuracy > 0 ? location.altitude : nil,
                takenAt: location.timestamp
            )
        }

        MainActor.assumeIsolated { finishFix(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Every failure means the same thing here — no fix — and the app's answer to all of
        // them is to keep using the epoch it already has. Nothing is surfaced: a chart that
        // announced "could not determine location" would be reporting an ordinary indoor
        // moment as a fault.
        BarosenseLog.pressure.info(
            "location fix failed: \(String(describing: error), privacy: .public)"
        )
        MainActor.assumeIsolated { finishFix(nil) }
    }
}

// MARK: - Protocol adapters

/// `LocationAccessReporting` on `CoreLocationService`.
///
/// A `struct` in front of the main-actor singleton rather than a conformance on the singleton
/// itself: the protocol is `Sendable` and its callers — `WeatherRequestBudget`, the settings
/// model — have no business being pinned to the main actor because CoreLocation is.
struct CoreLocationAccessReporter: LocationAccessReporting {

    func accessState() async -> LocationAccessState {
        await CoreLocationService.shared.accessState()
    }

    func requestAccess() async {
        await CoreLocationService.shared.requestAccess()
    }
}

/// `LocationFixProviding` on `CoreLocationService`.
struct CoreLocationFixProvider: LocationFixProviding {

    func currentFix() async -> LocationFix? {
        await CoreLocationService.shared.currentFix()
    }
}

/// `PlaceNaming` on `CLGeocoder`.
///
/// A fresh geocoder per call, deliberately: `CLGeocoder` holds one request at a time and the
/// caller above it already guarantees there is at most one call per epoch
/// (`LocationEpochRecorder`), so there is nothing for a long-lived instance to coalesce.
struct CLGeocoderPlaceNamer: PlaceNaming {

    func placeName(for coordinate: GeoCoordinate) async -> PlaceName? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // A throw is the throttled case, the offline case and the middle-of-the-ocean case at
        // once. All three mean "no name today", which the caller renders as no place line.
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil
        }

        return PlaceName(locality: placemark.locality,
                         administrativeArea: placemark.administrativeArea,
                         country: placemark.country)
    }
}
