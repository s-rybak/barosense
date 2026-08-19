import SwiftUI

/// The screen that explains what WeatherKit buys and what turning it off costs.
///
/// ## Why it exists even though the switch ships on
///
/// The default is on because the trade is favourable and the cost to the user is a coordinate,
/// not health data. But "on by default" and "never explained" are different things, and a
/// network feature the user was never told about is the kind of thing App Review reads
/// closely. So the switch ships on and this screen runs once, before the first request —
/// `WeatherForecastRefresher` will not ask WeatherKit anything until it has.
///
/// ## The sentence this screen exists to get right
///
/// Turning WeatherKit off does **not** remove the forecast. It shortens it: the app falls back
/// to a model fitted on the user's own barometer readings, which reaches hours ahead instead
/// of days, with a visibly wider band. Copy claiming the forecast disappears would be simply
/// untrue, and `.claude/context/pressure-forecast-spec.md` §2.1 names it as the wrong wording.
struct WeatherKitPrimer: View {

    let onAccept: () -> Void
    let onDecline: () -> Void

    private static let sectionSpacing: CGFloat = 24
    private static let horizontalInset: CGFloat = 24
    private static let actionHeight: CGFloat = 56
    private static let actionRadius: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    Text("Pressure, days ahead")
                        .font(Typography.onboardingTitleCompact)
                        .foregroundStyle(Palette.heading)
                        .accessibilityAddTraits(.isHeader)

                    Text("""
                        Barosense can use Apple Weather to extend the pressure chart past \
                        today. Your phone measures what the pressure is now; Apple Weather \
                        is what lets the chart carry on into the next few days.
                        """)
                        .font(Typography.onboardingBodySmall)
                        .foregroundStyle(Palette.bodyText)
                        .fixedSize(horizontal: false, vertical: true)

                    terms
                }
                .padding(.horizontal, Self.horizontalInset)
                .padding(.top, 30)
                .padding(.bottom, Self.sectionSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            actions
        }
        .background(Palette.surface)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }

    private var terms: some View {
        VStack(spacing: 10) {
            // The exact payload, stated as a fact the user can hold the app to.
            MarkerRow(text: "Sends only your approximate area and the time",
                      marker: Palette.markerCool)

            // Interpolated from the budget rather than typed, the way the reminder primer
            // interpolates the notification cap: a number raised in code and left at four on
            // this screen would be a promise the app quietly stopped keeping.
            MarkerRow(text: "At most \(WeatherRequestBudget.dailyRequestLimit) checks a day",
                      marker: Palette.markerCool)

            MarkerRow(text: "Nothing about you or how you feel ever leaves your phone",
                      marker: Palette.markerCool)

            MarkerRow(text: "Off at any time — the forecast then reaches hours ahead instead of days",
                      marker: Palette.markerCool)
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Button(action: onAccept) {
                Text("Use Apple Weather")
                    .font(Typography.primaryAction)
                    .foregroundStyle(Palette.onInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.actionHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Self.actionRadius, style: .continuous)
                            .fill(Palette.ink)
                    )
            }
            .buttonStyle(.plain)

            Button(action: onDecline) {
                Text("Not now")
                    .font(Typography.tertiaryAction)
                    .foregroundStyle(Palette.placeholder)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.bottom, 12)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            WeatherKitPrimer(onAccept: {}, onDecline: {})
        }
}
