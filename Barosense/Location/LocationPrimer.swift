import SwiftUI

/// The screen that asks before iOS does.
///
/// Same reasoning as `CheckInReminderPrimer`, on a different permission: iOS presents
/// `requestWhenInUseAuthorization()` exactly once per install, and after it has been answered
/// the call silently does nothing. A dialog raised with no context is answered "Don't Allow",
/// and the only way back is a trip to Settings almost nobody makes. So the app explains
/// first, and only a tap on its own button reaches iOS.
///
/// ## Why the three rows
///
/// They answer what somebody deciding this actually wants to know: *what is it for*, *how
/// precisely*, and *what does saying no cost me*. The third is the one this app can answer
/// unusually well, and it says so plainly — refusing does not remove the forecast, it
/// shortens it. Wording that claimed otherwise would be false, and it is the exact sentence
/// `.claude/context/pressure-forecast-spec.md` §2.1 calls out as wrong.
struct LocationPrimer: View {

    /// Raises the system prompt. The only path from this screen to iOS.
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
                    Text("A forecast for where you are")
                        .font(Typography.onboardingTitleCompact)
                        .foregroundStyle(Palette.heading)
                        .accessibilityAddTraits(.isHeader)

                    Text("""
                        Pressure moves differently in different places. With your location, \
                        Barosense can show what the pressure is expected to do near you over \
                        the next few days.
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
            // "Approximate" is the literal shipped behaviour, not a softener:
            // `NSLocationDefaultAccuracyReduced` means the prompt does not even offer precise
            // location, and `LocationEpochResolver` rounds what it gets to ~11 km.
            MarkerRow(text: "Approximate area only — never a precise position",
                      marker: Palette.markerCool)

            MarkerRow(text: "Used while the app is open, never in the background",
                      marker: Palette.markerCool)

            // The honest cost of "not now". Copy that said the forecast disappears without
            // location would be untrue — the app falls back to its own short-range forecast
            // built from your own readings.
            MarkerRow(text: "Without it, the forecast still works — it just reaches hours ahead instead of days",
                      marker: Palette.markerCool)
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Button(action: onAccept) {
                Text("Use my location")
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
            LocationPrimer(onAccept: {}, onDecline: {})
        }
}
