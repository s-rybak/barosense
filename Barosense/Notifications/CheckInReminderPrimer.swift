import SwiftUI

/// The screen that asks before iOS does.
///
/// ## Why this exists at all
///
/// iOS shows the notification permission dialog once. A refusal cannot be re-asked from inside
/// the app — the only way back is a trip to Settings that almost nobody makes — so the app gets
/// exactly one chance, and what it spends that chance on is the whole design problem. A system
/// dialog raised on first launch is answered without context, and the reflex answer is no.
///
/// So the app asks first, in its own words, and only a tap on "turn these on" reaches iOS. "Not
/// now" costs nothing that cannot be recovered: the switch in Settings raises the real prompt
/// later, still for the first time.
///
/// ## Why the three rows
///
/// They are the three questions somebody deciding this actually has — *when will it arrive*, *how
/// often*, and *can I stop it* — and the middle one is the one nobody believes without a number.
/// The cap is read from `NotificationBudget` rather than typed, so the promise on screen cannot
/// drift from the promise in the code.
struct CheckInReminderPrimer: View {

    /// Raises the system prompt. The only path from this screen to iOS.
    let onAccept: () -> Void

    /// Declines, durably. See `CheckInReminderController.declinePrimer`.
    let onDecline: () -> Void

    /// The same pair every other sheet in the app uses, so the set reads as one app.
    private static let sectionSpacing: CGFloat = 24
    private static let horizontalInset: CGFloat = 24
    private static let actionHeight: CGFloat = 56
    private static let actionRadius: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    Text("A reminder to check in")
                        .font(Typography.onboardingTitleCompact)
                        .foregroundStyle(Palette.heading)
                        .accessibilityAddTraits(.isHeader)

                    Text("""
                        Barosense can ask how you're feeling at the time of day you already \
                        tend to check in.
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
        // No drag-away. Both answers are one tap and neither is buried, so the only thing a
        // swipe could add is a fourth outcome — dismissed without answering — that the stored
        // "has been offered" flag would have to represent as one of the other two anyway.
        .interactiveDismissDisabled()
    }

    // MARK: - What is being agreed to

    private var terms: some View {
        VStack(spacing: 10) {
            MarkerRow(text: "At the hour your own check-ins cluster around",
                      marker: Palette.markerCool)

            // Interpolated from the budget, not typed. A cap that was raised in code and left
            // at three on this screen would be a promise the app quietly stopped keeping.
            MarkerRow(text: "Never more than \(NotificationBudget.dailySendLimit) notifications a day",
                      marker: Palette.markerCool)

            MarkerRow(text: "Off at any time, in Settings", marker: Palette.markerCool)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 0) {
            Button(action: onAccept) {
                Text("Turn on reminders")
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
                    // Padding rather than a height: the label is short and the tap target
                    // still has to clear 44 pt.
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
            CheckInReminderPrimer(onAccept: {}, onDecline: {})
        }
}
