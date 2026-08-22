import CoreLocation
import Foundation
import WeatherKit

/// `WeatherForecastProviding` on Apple's WeatherKit.
///
/// The **only** outbound network path in this app, and it carries a coordinate and a time.
/// Never a check-in, never a Health value, never anything derived from one — `CLAUDE.md`
/// constraint 2. The payload is decided entirely by the two arguments below, which is what
/// makes that claim reviewable rather than a promise.
///
/// ## One request, two datasets
///
/// `.current` and `.hourly` are asked for together. One `weather(for:including:)` call is one
/// unit of quota however many datasets it names, so the current conditions — the value the
/// offset calibrator most needs, because it can be compared with a barometer reading taken at
/// the same instant — are free.
///
/// ## Not testable on this machine, by Apple's design
///
/// WeatherKit does not serve the Simulator, and it needs an explicit App ID with WeatherKit
/// enabled under both App Services and App Capabilities. `DEVELOPMENT_TEAM` in `project.yml`
/// is empty, which is a human's decision to make. Everything above this file is exercised
/// against a double instead; this type stays as close to a straight translation as it can be
/// so that there is as little as possible in it that a test would have wanted to check.
struct WeatherKitForecastProvider: WeatherForecastProviding {

    func forecast(for coordinate: GeoCoordinate,
                  asOf now: Date) async throws -> WeatherForecastIssue {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        do {
            // **The range is explicit, and it has to be.** Bare `.hourly` is served with
            // WeatherKit's own default window of about 24 hours, so the app was archiving a day
            // and drawing chart buttons that promised two and four — see
            // `WeatherForecastPolicy.requestedHorizonSeconds` for the measurement.
            //
            // It starts an hour behind `now` rather than at it, so the hour *containing* `now`
            // is in the response. `ForecastPressurePoint.curve(includingHourAt:)` needs that
            // row: every delta in `ForecastPressureFeatures` is measured against the level at
            // `now`. A window opening exactly at `now` would not leave that level missing —
            // the extractor matches within 90 minutes, so the next whole hour would answer for
            // it — which is worse than missing. Every delta would then be measured from a point
            // up to an hour *ahead* of `now`, understating each one by that much of the drift
            // already under way, silently and in the same direction every time.
            let (current, hourly) = try await WeatherService.shared.weather(
                for: location,
                including: .current,
                .hourly(
                    startDate: now.addingTimeInterval(-3600),
                    endDate: now.addingTimeInterval(WeatherForecastPolicy.requestedHorizonSeconds)
                )
            )

            // `now` — the instant the app asked — rather than the response's own metadata
            // date. The model run behind a response happened earlier, and stamping rows with
            // it would let a feature computed between the run and this call read a curve the
            // device did not yet have. See `WeatherForecastPoint.issuedAt`.
            var points = [point(issuedAt: now,
                                validAt: current.date,
                                pressure: current.pressure,
                                temperature: current.temperature)]

            points += hourly.forecast.map {
                point(issuedAt: now,
                      validAt: $0.date,
                      pressure: $0.pressure,
                      temperature: $0.temperature)
            }

            return WeatherForecastIssue(issuedAt: now, points: points)
        } catch {
            throw WeatherForecastError.serviceRefused(underlying: error)
        }
    }

    func history(for coordinate: GeoCoordinate,
                 in range: Range<Date>) async throws -> [WeatherObservation] {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        do {
            let hourly = try await WeatherService.shared.weather(
                for: location,
                including: .hourly(startDate: range.lowerBound, endDate: range.upperBound)
            )

            return hourly.forecast.map {
                WeatherObservation(validAt: $0.date,
                                   meanSeaLevelPressureHPa: hectopascals($0.pressure),
                                   temperatureC: celsius($0.temperature))
            }
        } catch {
            throw WeatherForecastError.serviceRefused(underlying: error)
        }
    }

    private func point(issuedAt: Date,
                       validAt: Date,
                       pressure: Measurement<UnitPressure>,
                       temperature: Measurement<UnitTemperature>) -> WeatherForecastPoint {
        WeatherForecastPoint(issuedAt: issuedAt,
                             validAt: validAt,
                             meanSeaLevelPressureHPa: hectopascals(pressure),
                             temperatureC: celsius(temperature))
    }

    /// The conversions the whole feature rests on, in `WeatherMeasurement` so that a test can
    /// reach them. This client cannot itself be exercised here — WeatherKit does not serve the
    /// Simulator — so the two lines most worth checking are the ones that live elsewhere.
    private func hectopascals(_ measurement: Measurement<UnitPressure>) -> Double {
        WeatherMeasurement.hectopascals(measurement)
    }

    private func celsius(_ measurement: Measurement<UnitTemperature>) -> Double {
        WeatherMeasurement.celsius(measurement)
    }
}
