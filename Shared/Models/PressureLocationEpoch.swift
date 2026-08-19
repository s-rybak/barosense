import Foundation

/// A coordinate the app is allowed to keep, at the resolution the app is allowed to keep it.
///
/// **0.1° is the storage contract, not a formatting choice.** That is ~11 km of latitude —
/// coarse enough that a row cannot say which street the user was on, fine enough for a
/// WeatherKit grid cell and for the 25 km epoch threshold to mean something. Rounding
/// happens once, in `LocationEpochResolver`, and nothing downstream ever sees the raw fix.
///
/// Deliberately not `CLLocationCoordinate2D`: this type is stored, compared and tested with
/// literals, and none of that should need CoreLocation on the other side of the call.
struct GeoCoordinate: Hashable, Codable, Sendable {

    /// Degrees north, −90...90.
    let latitude: Double

    /// Degrees east, −180...180.
    let longitude: Double
}

/// Where the app believes the user is, in words.
///
/// Three fields because that is what the card under the chart prints, and because any one of
/// them can be absent: a reverse geocode over open water returns a country and nothing else,
/// and a village that Apple's geocoder does not name returns a region.
///
/// The words are the geocoder's, not the user's, so they are not free text in the
/// `CheckIn.note` sense — but they are still never in an outbound payload. Nothing leaves the
/// device (`CLAUDE.md` constraint 2); a WeatherKit request carries a coordinate and a time.
struct PlaceName: Hashable, Codable, Sendable {

    /// City or town.
    let locality: String?

    /// Region, oblast, state.
    let administrativeArea: String?

    let country: String?

    init(locality: String? = nil, administrativeArea: String? = nil, country: String? = nil) {
        self.locality = locality
        self.administrativeArea = administrativeArea
        self.country = country
    }

    /// City · region · country as one line, or `nil` when the geocoder returned nothing.
    ///
    /// The region is dropped when it merely repeats the city: "Kyiv, Kyiv, Ukraine" is what
    /// Apple's geocoder returns for a city that is its own administrative area, and printing
    /// it back is how an app looks broken.
    ///
    /// On the model rather than in a view because two surfaces print it — the chart card and
    /// the Settings row — and two copies of the de-duplication is how they stop agreeing.
    var description: String? {
        var seen: Set<String> = []
        let parts = [locality, administrativeArea, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Whether the geocoder returned anything worth printing. An epoch with an empty name is
    /// ordinary — the geocoder is throttled and can simply decline — and the card then shows
    /// the chart without a place line rather than an empty one.
    var isEmpty: Bool {
        locality == nil && administrativeArea == nil && country == nil
    }
}

/// One stretch of time during which the user was in one place.
///
/// ## Why an epoch and not a field on the sample
///
/// The obvious design puts city / region / country on every `PressureSample`. At the shipped
/// cadence that is ~2 900 rows a month each carrying a place name — a text movement trail,
/// stored forever, that nothing in the app needs. An epoch is written when the user actually
/// moves 25 km, which for most people is a few rows a year.
///
/// The sample then carries `locationEpochID` and nothing else, which is enough for every
/// consumer: the offset calibrator needs to know that a stretch of barometer history and a
/// stretch of WeatherKit history describe the same place, and that is exactly what an epoch
/// identity is.
///
/// ## Retention
///
/// The same five years the barometer log keeps (`PressureRetentionPolicy`). An epoch outlives
/// the samples that point at it by construction — it is written first — so pruning epochs on
/// their own horizon would orphan rows the calibrator still reads. They are removed with
/// everything else by `BarosenseDataEraser`.
struct PressureLocationEpoch: Identifiable, Hashable, Codable, Sendable {

    let id: UUID

    /// Rounded to 0.1° before it ever reaches this type. See `GeoCoordinate`.
    let coordinate: GeoCoordinate

    /// What the reverse geocode returned, if it returned anything. Resolved **once per
    /// epoch** — Apple's geocoder is throttled and its limits are not published, so an app
    /// that re-geocoded on every activation would be rate-limited into returning nothing.
    let place: PlaceName

    /// Metres above sea level, as reported by the fix that opened the epoch.
    ///
    /// Optional because a reduced-accuracy fix does not carry a useful one, and that is the
    /// shipped default (`NSLocationDefaultAccuracyReduced`). It is a note, never a
    /// correction: the station-to-MSLP offset is measured from the data
    /// (`PressureOffsetCalibrator`), not computed from an altitude the app half knows.
    let altitudeMetres: Double?

    /// When this epoch became the current one. The previous epoch ends here; there is no
    /// `endedAt` field, because an epoch's end is the next one's start and storing both is a
    /// second place for the two to disagree.
    let startedAt: Date

    init(id: UUID = UUID(),
         coordinate: GeoCoordinate,
         place: PlaceName = PlaceName(),
         altitudeMetres: Double? = nil,
         startedAt: Date) {
        self.id = id
        self.coordinate = coordinate
        self.place = place
        self.altitudeMetres = altitudeMetres
        self.startedAt = startedAt
    }

    /// The same epoch with a name attached. Used by the one geocode an epoch is allowed:
    /// the row is written as soon as the fix lands, so the forecast can be requested without
    /// waiting on a throttled network round trip, and the name is filled in when it arrives.
    func namingPlace(_ place: PlaceName) -> PressureLocationEpoch {
        PressureLocationEpoch(id: id,
                              coordinate: coordinate,
                              place: place,
                              altitudeMetres: altitudeMetres,
                              startedAt: startedAt)
    }
}
