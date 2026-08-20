import Foundation

/// Why a forecast could not be fetched.
enum WeatherForecastError: Error, Sendable {

    /// No coordinate to ask about. A fresh install before its first fix, or one where location
    /// was refused. Not a failure to report — it is the state the local model exists for.
    case noLocation

    /// WeatherKit refused, or the network did.
    ///
    /// Ordinary in the Simulator, which does not serve WeatherKit at all, and on any build
    /// whose `DEVELOPMENT_TEAM` has no App ID with the two WeatherKit tabs enabled. Both mean
    /// the same thing here: no rows this pass.
    case serviceRefused(underlying: Error)
}

/// The boundary between Barosense and WeatherKit.
///
/// A protocol so everything above it — the archive, the request budget, the offset calibrator,
/// the features — runs from a plain unit test with no network and no entitlement. That is not
/// a nicety here: WeatherKit **does not work in the Simulator** at all
/// (`.claude/context/pressure-forecast-spec.md` §3, fact 7), so a design that could only be
/// exercised through the real client could not be exercised on this machine.
///
/// Deliberately two methods with two return types. Forecast rows carry `issuedAt`; historical
/// rows cannot, because a historical response does not say when anybody first knew it. Making
/// that a type distinction rather than a comment is what stops history being fed into a
/// forward-looking feature by accident — the leak §4.5 is entirely about.
protocol WeatherForecastProviding: Sendable {

    /// Current conditions plus the hourly curve, in **one** request.
    ///
    /// One `weather(for:including:)` call is one unit of quota regardless of how many datasets
    /// it asks for, so asking for both together costs what asking for one would.
    ///
    /// `now` is threaded in rather than read from the clock so `issuedAt` is the same instant
    /// the budget's own counter is stamped with — two readings of the clock would put a row a
    /// millisecond outside the slot it was taken for.
    func forecast(for coordinate: GeoCoordinate, asOf now: Date) async throws -> WeatherForecastIssue

    /// Past hours, for offset calibration only.
    ///
    /// Safe to request and safe to store, and **not** safe to use as a forward-looking
    /// feature: calibration compares a station reading and an MSLP value at the same instant,
    /// which leaks nothing, while a forecast feature needs to know when the value became
    /// knowable, which history does not carry.
    ///
    /// WeatherKit serves history from 2021-08-01 and at most ten days per request.
    func history(for coordinate: GeoCoordinate,
                 in range: Range<Date>) async throws -> [WeatherObservation]
}

/// One past hour, as WeatherKit reports it.
///
/// No `issuedAt`, on purpose. See `WeatherForecastProviding`.
struct WeatherObservation: Hashable, Codable, Sendable {

    let validAt: Date
    let meanSeaLevelPressureHPa: Double
    let temperatureC: Double

    /// The archive row this observation becomes.
    ///
    /// `issuedAt == validAt` is the honest stamp: an observation was knowable at the hour it
    /// describes and at no earlier one. It is also what makes these rows structurally unable
    /// to leak — a feature at `t` reads issues with `issuedAt <= t` and looks at points with
    /// `validAt > t`, and an observation can never satisfy both.
    func asArchivedPoint() -> WeatherForecastPoint {
        WeatherForecastPoint(issuedAt: validAt,
                             validAt: validAt,
                             meanSeaLevelPressureHPa: meanSeaLevelPressureHPa,
                             temperatureC: temperatureC)
    }
}

/// A provider that serves nothing. The watch's, the preview's, and the one the app uses when
/// the kill switch is off.
///
/// Throws rather than returning an empty issue: an empty curve is a claim that the service
/// answered and had nothing to say, and the caller's response to that is different from its
/// response to "no service".
struct UnavailableWeatherForecastProvider: WeatherForecastProviding {

    func forecast(for coordinate: GeoCoordinate, asOf now: Date) async throws -> WeatherForecastIssue {
        throw WeatherForecastError.serviceRefused(underlying: WeatherForecastError.noLocation)
    }

    func history(for coordinate: GeoCoordinate, in range: Range<Date>) async throws -> [WeatherObservation] {
        []
    }
}
