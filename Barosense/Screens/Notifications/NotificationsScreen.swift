import SwiftUI

/// The bell, with a count of what has arrived and not been looked at.
///
/// Drawn as an SF Symbol rather than a hand-built glyph, the way `SettingsChevron` is: there
/// is no bell in the Figma library to trace, and the system symbol scales with Dynamic Type
/// and stays optically centred at every size on its own.
///
/// The count comes from the log the app already holds in memory (`NotificationsController`),
/// so drawing it costs nothing: no timer, no poll, no extra read. It moves when a pass runs —
/// foreground activation, or a check-in being written — and at no other time.
struct NotificationBell: View {

    let unreadCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bell")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 40, height: 40)
                .background(Palette.cardSurface, in: .circle)
                .overlay {
                    Circle().strokeBorder(Palette.cardBorder, lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    if unreadCount > 0 { badge }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Notifications"))
        // The badge is a second channel for the same fact, not a decoration, so it is spoken
        // rather than left as a red dot a screen reader never mentions.
        // "New: 2" rather than "2 new": the second form needs a plural table in every language
        // the app ships, and Ukrainian has three plural categories for it. A label and a
        // number reads the same to VoiceOver and cannot be grammatically wrong.
        .accessibilityValue(unreadCount > 0 ? Text("New: \(unreadCount)") : Text("Nothing new"))
    }

    private var badge: some View {
        Text(unreadCount, format: .number)
            .font(Typography.captionEmphasis)
            .foregroundStyle(Palette.onInk)
            .padding(.horizontal, 5)
            .frame(minWidth: 17, minHeight: 17)
            .background(Palette.destructive, in: .capsule)
            .offset(x: 3, y: -2)
            .accessibilityHidden(true)
    }
}

/// What Barosense has sent, what it is about to send, and what it held back.
///
/// The log rendered directly — every row here is a row in the database, including the ones
/// that never reached the user. That is the point of storing them: "you have had your three
/// for today" is a different answer from "nothing was planned", and only a log can tell them
/// apart.
struct NotificationsScreen: View {

    let controller: NotificationsController
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: SettingsMetrics.blockSpacing) {
                header
                summaryCard

                if controller.snapshot.history.isEmpty {
                    emptyState
                } else {
                    historyCard
                }
            }
            .padding(.horizontal, SettingsMetrics.screenInset)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Palette.surface.ignoresSafeArea())
        .scrollBounceBehavior(.basedOnSize)
        // Marking read on appearance rather than on dismissal: by the time this screen is up,
        // the rows have been seen.
        .task { await controller.markHistoryRead() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Notifications")
                .font(Typography.screenHeading)
                .foregroundStyle(Palette.heading)

            Spacer(minLength: 12)

            Button(action: close) {
                Text("Done")
                    .font(Typography.navigationAction)
                    .foregroundStyle(Palette.link)
                    .frame(height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Summary

    /// Today's allowance and what is next. The same `NotificationBudgetStatus` the Settings
    /// section prints and the same one dispatch spends, so the two cannot drift.
    private var summaryCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sent today")
                    .font(Typography.settingsRowLabel)
                    .foregroundStyle(Palette.heading)

                Text("\(controller.snapshot.budget.used) of \(controller.snapshot.budget.limit)")
                    .font(Typography.metricValue)
                    .foregroundStyle(Palette.inkStrong)

                nextLine
                    .font(Typography.settingsCaption)
                    .foregroundStyle(Palette.placeholder)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
            .padding(.vertical, SettingsMetrics.rowVerticalInset)
        }
    }

    private var nextLine: Text {
        guard controller.snapshot.isCheckInReminderActive else {
            return Text("Reminders are off.")
        }
        guard let next = controller.snapshot.nextReminderAt else {
            return Text("Nothing scheduled.")
        }
        return Text("Next: \(next, format: .dateTime.day().month(.abbreviated).hour().minute())")
    }

    // MARK: - History

    private var historyCard: some View {
        SettingsCard {
            ForEach(Array(controller.snapshot.history.enumerated()), id: \.element.id) { index, row in
                if index > 0 { SettingsRowDivider() }
                NotificationRow(notification: row)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing yet")
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.heading)

            Text("""
                Every reminder Barosense sends is recorded here, including the ones it holds \
                back when the daily limit is reached.
                """)
                .font(Typography.settingsCaption)
                .foregroundStyle(Palette.placeholder)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// One logged notification: what it was, when it was due, and what became of it.
private struct NotificationRow: View {

    let notification: AppNotification

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            unreadMarker

            VStack(alignment: .leading, spacing: 3) {
                Text(notification.kind.title)
                    .font(Typography.settingsRowLabel)
                    .foregroundStyle(Palette.heading)

                Text(notification.scheduledFor,
                     format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(Typography.settingsCaption)
                    .foregroundStyle(Palette.placeholder)

                Text(notification.state.caption)
                    .font(Typography.settingsCaption)
                    .foregroundStyle(notification.state.isSetback ? Palette.destructive : Palette.inkSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, SettingsMetrics.rowVerticalInset)
        .frame(minHeight: SettingsMetrics.rowMinHeight, alignment: .top)
    }

    /// A dot beside a row the user has not seen. Never the only channel — the row is also
    /// first in the list, and the state line under it says what happened.
    @ViewBuilder
    private var unreadMarker: some View {
        Circle()
            .fill(notification.isUnread ? Palette.link : .clear)
            .frame(width: 7, height: 7)
            .padding(.top, 6)
            .accessibilityHidden(true)
    }
}

// MARK: - Copy

extension AppNotificationKind {

    /// What this kind is called in the list. Copy, so it lives in the app target — `Shared/`
    /// stores the kind and never a rendered string.
    var title: LocalizedStringKey {
        switch self {
        case .checkInReminder: "Check-in reminder"
        }
    }
}

extension NotificationDeliveryState {

    /// One line saying what became of a notification.
    ///
    /// Every suppression says *why*. "Not sent" on its own reads as a bug; "held back — you
    /// have had today's three" reads as the app doing what it promised.
    var caption: LocalizedStringKey {
        switch self {
        case .pending: "Queued"
        case .scheduled: "Scheduled"
        case .delivered: "Sent"
        case .cancelled: "Withdrawn — you checked in already"
        case .suppressed(.dailyLimit): "Held back — today's limit was reached"
        case .suppressed(.permissionDenied): "Not sent — notifications are off for Barosense"
        case .suppressed(.remindersOff): "Not sent — reminders are off"
        case .suppressed(.missedItsMoment): "Not sent — its time had already passed"
        }
    }

    /// Whether the line should be drawn as something that did not go to plan.
    var isSetback: Bool {
        if case .suppressed = self { return true }
        return false
    }
}

#Preview {
    NotificationsScreen(controller: .preview, close: {})
}
