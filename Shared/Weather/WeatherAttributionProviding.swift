import Foundation

/// What Apple requires to be on screen wherever WeatherKit data is shown.
///
/// Not a nicety and not a credit line: displaying the Apple Weather trademark **and** a link to
/// the legal attribution page is a condition of the WeatherKit terms, so an app that draws a
/// WeatherKit curve without it is shipping data it has not met the terms for. It is also the
/// kind of thing App Review checks against the entitlement in the build.
///
/// The values are read from the service rather than hard-coded — Apple publishes the mark and
/// the page through `WeatherAttribution` precisely so that a change to either does not need an
/// app update. Nothing here is localised by this app: a trademark is not translated, and the
/// legal page picks its own language.
struct WeatherDataAttribution: Hashable, Sendable {

    /// Apple's own name for the service, e.g. `Apple Weather`. Shown verbatim, and used as the
    /// label when the mark image cannot be loaded.
    let serviceName: String

    /// The page the mark has to link to.
    let legalPageURL: URL

    /// The combined mark, in the two appearances Apple publishes it for. This app is pinned to
    /// the light appearance (`project.yml`, `UIUserInterfaceStyle`), so the light one is what
    /// is drawn today; both are carried because that pin is a note to be removed, not a rule.
    let markLightURL: URL
    let markDarkURL: URL
}

/// Where `WeatherDataAttribution` comes from.
///
/// A protocol for the same reason `WeatherForecastProviding` is one: WeatherKit does not serve
/// the Simulator, so anything that only exists behind the real client cannot be exercised on
/// this machine.
protocol WeatherAttributionProviding: Sendable {

    /// `nil` when the service will not say — offline, or a build without the entitlement. The
    /// caller's answer is to draw no WeatherKit data rather than to draw it unattributed; in
    /// practice the same build states are the ones where there is no curve to draw either.
    func attribution() async -> WeatherDataAttribution?
}

/// A provider that has nothing to say, for previews and for the watch — neither displays
/// WeatherKit data.
struct UnattributedWeatherProvider: WeatherAttributionProviding {

    func attribution() async -> WeatherDataAttribution? { nil }
}
