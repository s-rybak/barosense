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

    /// Every epoch that describes the same place as `current`, by this type's own definition
    /// of "same place".
    ///
    /// The epoch table is not a list of places — it is a list of *arrivals*. `resolve` only
    /// ever compares a fix against the epoch that is current, so a user who commutes past the
    /// threshold writes a new row every leg: home, work, home again. The third row carries the
    /// first one's coordinate, because both rounded onto the same 0.1° cell, and counting them
    /// as different places would throw away half the history of somewhere the user has been
    /// living all along.
    ///
    /// So membership is measured the way the threshold is: within `newEpochThresholdMetres` of
    /// where the user is now. That makes "same place" the same relation in both directions —
    /// a fix that would have been `.reuse`d is a place whose old rows are usable.
    ///
    /// `nil` for `current` — a fresh install, an erase, location never granted — yields `nil`
    /// rather than an empty set, and callers read that as "there is nothing to filter on".
    /// An empty set would mean the opposite and would silently discard every reading.
    static func samePlaceEpochIDs(as current: PressureLocationEpoch?,
                                  among all: [PressureLocationEpoch]) -> Set<UUID>? {
        guard let current else { return nil }

        let here = all.filter {
            distanceMetres(from: current.coordinate, to: $0.coordinate) < newEpochThresholdMetres
        }

        return Set(here.map(\.id)).union([current.id])
    }

    /// The readings taken where the user is now.
    ///
    /// This is what `PressureSample.locationEpochID` is *for*: the offset between the
    /// barometer and mean-sea-level pressure is dominated by elevation, so a 48 h median that
    /// straddles a move blends two places' offsets into one number. At 180 m — Kyiv — the
    /// offset is about −22 hPa and at the coast it is 0, so the blend is not a rounding error;
    /// it is the whole quantity.
    ///
    /// Two cases are deliberately **not** filtered, because in both of them the stamp says
    /// nothing rather than says "elsewhere":
    ///
    /// - `epochIDs == nil` — there is no current epoch. Location was refused or has never
    ///   resolved, and the barometer works without it.
    /// - no reading in the batch carries any stamp at all — rows written before the epoch
    ///   table existed, or before this install's first fix.
    ///
    /// A batch that *is* stamped, but not with anywhere near here, correctly comes back
    /// short or empty: the caller's answer to that is to report nothing rather than to report
    /// the previous city's number.
    ///
    /// The **mixed** batch — some rows stamped, some not — is the case `unstamped` exists for,
    /// and it is not a corner. `PressureSample.locationEpochID` arrived with this feature, so
    /// on every install that predates it the log is unstamped history plus stamped rows from
    /// the update onwards, and `.excluded` throws the whole history away the moment the first
    /// stamped row lands. See `UnstampedPolicy`.
    static func readings(_ samples: [PressureSample],
                         takenAt epochIDs: Set<UUID>?,
                         unstamped: UnstampedPolicy = .excluded) -> [PressureSample] {
        guard let epochIDs, samples.contains(where: { $0.locationEpochID != nil }) else {
            return samples
        }

        return samples.filter {
            $0.locationEpochID.map(epochIDs.contains) ?? (unstamped == .included)
        }
    }

    /// What a reading with no epoch stamp means to the caller doing the filtering.
    ///
    /// The two callers want opposite answers and both are right, because they are measuring
    /// different quantities from the same rows.
    ///
    /// `PressureOffsetCalibrator` takes a **median of station − MSLP over 48 h**. Elevation is
    /// that quantity — at Kyiv's 180 m the offset is ~−22 hPa and at the coast it is 0 — so a
    /// window blending two places does not return a slightly worse number, it returns a number
    /// describing nowhere. It wants `.excluded`, and pays at most 48 h of no WeatherKit curve
    /// after an update for it.
    ///
    /// `LocalPressureModel.fit` takes an **autoregressive fit over 30 days** whose forecast
    /// level comes from the seed — the last three consecutive hours, which are always recent
    /// and therefore always here. A step in the middle of the window costs the three rows that
    /// straddle it and widens the residual band, which is the model saying it knows less. It
    /// wants `.included`, because the alternative on an updated install is a month of silence
    /// on a log that is sitting right there.
    enum UnstampedPolicy: Equatable {

        /// An unstamped row is not from here. Correct when a blend would be the whole error.
        case excluded

        /// An unstamped row says nothing about where it was taken, which is not the same as
        /// saying elsewhere. The reading is kept.
        case included
    }

    private static func round(_ value: Double, to step: Double) -> Double {
        // Re-rounded to six places because `(value / step).rounded() * step` lands on
        // 50.400000000000006 for perfectly ordinary inputs, and that value then differs from
        // the literal a test writes and from the same coordinate resolved on the next launch.
        ((value / step).rounded() * step * 1_000_000).rounded() / 1_000_000
    }
}
