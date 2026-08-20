import Foundation
import WeatherKit

/// `WeatherAttributionProviding` on Apple's WeatherKit.
///
/// As thin as `WeatherKitForecastProvider`, and for the same reason: it cannot be exercised on
/// this machine, so there should be as little in it as possible that a test would have wanted
/// to check.
///
/// `WeatherService.attribution` is a network read the first time and cached by the framework
/// afterwards. It is only ever asked for on a screen that is already drawing a WeatherKit
/// curve, so it adds no request to a device that has the feature switched off.
struct WeatherKitAttributionProvider: WeatherAttributionProviding {

    func attribution() async -> WeatherDataAttribution? {
        guard let attribution = try? await WeatherService.shared.attribution else { return nil }

        return WeatherDataAttribution(serviceName: attribution.serviceName,
                                      legalPageURL: attribution.legalPageURL,
                                      markLightURL: attribution.combinedMarkLightURL,
                                      markDarkURL: attribution.combinedMarkDarkURL)
    }
}
