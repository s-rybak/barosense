import SwiftUI

/// The Apple Weather mark and its legal link, under whatever is drawing WeatherKit data.
///
/// Deliberately a link and not a caption: the WeatherKit terms ask for the trademark *and* a
/// way to reach the legal attribution page, and a mark with nothing behind it meets half of
/// that.
///
/// The mark is fetched from the URL the service publishes; `serviceName` is the label while it
/// loads and the label if it never does. That ordering is the point — the trademark is the
/// required part, the image is the preferred rendering of it, and a device that is offline or
/// an asset format `AsyncImage` cannot decode leaves the requirement met rather than blank.
struct AppleWeatherAttribution: View {

    let attribution: WeatherDataAttribution

    /// The app is pinned to the light appearance today, but the mark is chosen from the
    /// environment rather than from that pin, so removing the pin does not leave a dark mark
    /// on a dark card.
    @Environment(\.colorScheme) private var colorScheme

    private enum Metrics {
        /// Apple publishes the combined mark at a height that reads at this size next to
        /// `Typography.cardNote`; taller and it competes with the card's own title.
        static let markHeight: CGFloat = 14
    }

    var body: some View {
        Link(destination: attribution.legalPageURL) {
            AsyncImage(url: colorScheme == .dark ? attribution.markDarkURL
                                                 : attribution.markLightURL) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                Text(verbatim: attribution.serviceName)
                    .font(Typography.cardNote)
                    .foregroundStyle(Palette.inkSubtle)
            }
            .frame(height: Metrics.markHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(Text(verbatim: attribution.serviceName))
        .accessibilityHint(Text("Opens the weather data attribution page"))
    }
}
