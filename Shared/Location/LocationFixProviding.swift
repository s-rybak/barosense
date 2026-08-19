import Foundation

/// One reading of where the device is.
///
/// Carries `takenAt` because a fix is allowed to be stale. `WeatherKit` needs *a* coordinate,
/// not a fresh one — the forecast is for a 0.1° grid cell, and the user has to travel 25 km
/// before the app considers itself somewhere else — so a cached fix from this morning is a
/// perfectly good input and costs no radio time to reuse. The age is carried so a caller can
/// say how old rather than having to assume.
struct LocationFix: Hashable, Sendable {

    /// Raw, unrounded. Rounding to 0.1° happens in `LocationEpochResolver` on the way into
    /// storage, so the threshold and the stored value are computed from one number.
    let coordinate: GeoCoordinate

    /// Metres above sea level, when the fix carries one. `nil` under reduced accuracy, which
    /// is the shipped default — see `LocationAccuracy`.
    let altitudeMetres: Double?

    let takenAt: Date

    init(coordinate: GeoCoordinate, altitudeMetres: Double? = nil, takenAt: Date) {
        self.coordinate = coordinate
        self.altitudeMetres = altitudeMetres
        self.takenAt = takenAt
    }
}

/// A single foreground location fix.
///
/// **Foreground only, and that is a design decision rather than an omission.** Apple documents
/// that a when-in-use app's attempts to start location updates in the background fail, and the
/// list of states that count as "in use" does not include `BGAppRefreshTask`
/// (`.claude/context/pressure-forecast-spec.md` §3, fact 4). The documented way around it,
/// `CLBackgroundActivitySession`, costs a permanent visible indicator and a Location Updates
/// capability — a bad trade for a forecast refreshed four times a day.
///
/// So the coordinate the scheduler uses is the newest epoch's, which was recorded during some
/// earlier foreground session. Nothing here ever runs from a background wake.
protocol LocationFixProviding: Sendable {

    /// One fix, or `nil` if the device would not give one.
    ///
    /// `nil` is ordinary: permission refused, location services off, a fix that timed out
    /// indoors. Every one of them has the same consequence — the app keeps using the epoch it
    /// already has — so they are not distinguished here.
    func currentFix() async -> LocationFix?
}

/// Turns a coordinate into words.
///
/// Behind a protocol for the usual reason and one extra: Apple's geocoder is throttled and its
/// limits are not published, so the rule that matters — **at most one call per epoch** — has
/// to be testable by counting calls on a double.
protocol PlaceNaming: Sendable {

    /// The place at `coordinate`, or `nil` when the geocoder declined.
    ///
    /// Declining is normal, not an error: throttling, no network, a coordinate over water.
    /// The epoch then keeps an empty `PlaceName` and the card simply shows no place line.
    func placeName(for coordinate: GeoCoordinate) async -> PlaceName?
}

/// A provider that never has a fix — previews, tests, and the watch, which never asks.
struct UnavailableLocationFixProvider: LocationFixProviding {
    func currentFix() async -> LocationFix? { nil }
}

/// A namer that names nothing. Keeps a preview and a test off `CLGeocoder`.
struct UnnamedPlaceNamer: PlaceNaming {
    func placeName(for coordinate: GeoCoordinate) async -> PlaceName? { nil }
}
