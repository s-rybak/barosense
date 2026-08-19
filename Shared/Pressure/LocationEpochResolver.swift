import Foundation

/// Decides whether a new fix is still the same place as the last one.
///
/// Pure arithmetic on two coordinate pairs. No `CLLocationManager`, no store, no geocoder —
/// which is the point: this is the rule that decides how often the app geocodes and how many
/// epoch rows a year it writes, and it has to be checkable from a test with literals.
enum LocationEpochResolver {

    /// How far the user has to move before the forecast is about somewhere else.
    ///
    /// 25 km, *provisional*. It is chosen against what the epoch is for rather than against a
    /// map: an epoch exists so the offset calibrator knows a stretch of barometer history and
    /// a stretch of WeatherKit history describe one place. WeatherKit's own grid and the
    /// station-to-MSLP offset both vary slowly over that scale, so a commute across a city
    /// does not need a new epoch and a move to the next oblast does.
    ///
    /// The failure modes are asymmetric, which is what fixes the order of magnitude. Too
    /// small and every commute writes an epoch and spends a throttled geocode; too large and
    /// the calibrator averages two places' offsets together, which on a 500 m difference in
    /// elevation is ~60 hPa of nonsense. 25 km is comfortably inside "one weather", and
    /// re-deriving it needs real traces (`.claude/context/pressure-forecast-spec.md` §7.2).
    static let newEpochThresholdMetres: Double = 25_000

    /// Storage resolution of a stored coordinate, in degrees.
    ///
    /// 0.1° ≈ 11 km of latitude. Enough for a WeatherKit request and for a cache key,
    /// deliberately not enough to reconstruct where somebody lives.
    static let coordinateResolutionDegrees: Double = 0.1

    /// Mean Earth radius, metres. The value the haversine below is defined against.
    private static let earthRadiusMetres: Double = 6_371_000

    /// Rounds a raw fix onto the 0.1° storage grid.
    ///
    /// Applied before anything is stored **and** before the threshold is measured, so the
    /// comparison and the stored value cannot disagree: a fix that rounds onto the same grid
    /// cell as the current epoch is zero metres away from it by definition, rather than
    /// 300 m away and rounding to the same row.
    static func rounded(_ coordinate: GeoCoordinate) -> GeoCoordinate {
        GeoCoordinate(latitude: round(coordinate.latitude, to: coordinateResolutionDegrees),
                      longitude: round(coordinate.longitude, to: coordinateResolutionDegrees))
    }

    /// Great-circle distance in metres.
    ///
    /// Haversine on a sphere, not the ellipsoid `CLLocation.distance(from:)` uses. The two
    /// differ by up to ~0.3%, which at the 25 km threshold is 75 m — three orders of
    /// magnitude below the *provisional* uncertainty in the threshold itself. What the sphere
    /// buys is a function that runs in a unit test without CoreLocation.
    static func distanceMetres(from origin: GeoCoordinate, to destination: GeoCoordinate) -> Double {
        let originLatitude = origin.latitude * .pi / 180
        let destinationLatitude = destination.latitude * .pi / 180
        let deltaLatitude = (destination.latitude - origin.latitude) * .pi / 180
        let deltaLongitude = (destination.longitude - origin.longitude) * .pi / 180

        let haversine = pow(sin(deltaLatitude / 2), 2)
            + cos(originLatitude) * cos(destinationLatitude) * pow(sin(deltaLongitude / 2), 2)

        return 2 * earthRadiusMetres * asin(min(1, sqrt(haversine)))
    }

    /// What a fix means for the epoch table.
    enum Decision: Equatable {

        /// Still the same place. Carries the epoch so the caller can stamp samples with it
        /// without a second store read.
        case reuse(PressureLocationEpoch)

        /// Far enough to be somewhere else, or the first fix this install has ever had.
        /// The coordinate is already rounded; the caller writes the row and spends its one
        /// geocode on it.
        case open(GeoCoordinate)
    }

    /// Resolves a raw fix against the epoch currently in the store.
    ///
    /// `current` is `nil` on a fresh install and after an erase, and both open an epoch —
    /// there is nothing to be near.
    static func resolve(fix: GeoCoordinate,
                        against current: PressureLocationEpoch?) -> Decision {
        let grid = rounded(fix)

        guard let current else { return .open(grid) }

        let travelled = distanceMetres(from: current.coordinate, to: grid)
        return travelled < newEpochThresholdMetres ? .reuse(current) : .open(grid)
    }

    private static func round(_ value: Double, to step: Double) -> Double {
        // Re-rounded to six places because `(value / step).rounded() * step` lands on
        // 50.400000000000006 for perfectly ordinary inputs, and that value then differs from
        // the literal a test writes and from the same coordinate resolved on the next launch.
        ((value / step).rounded() * step * 1_000_000).rounded() / 1_000_000
    }
}
