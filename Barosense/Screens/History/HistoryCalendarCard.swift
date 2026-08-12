import SwiftUI

/// The month grid on the History screen (Figma `M3 · Історія`).
///
/// One cell per day of the month, filled in the colour of the **highest** intensity recorded
/// that day — see `HistoryDay.peakIntensity` for why the peak and not the mean.
///
/// A day with no check-in is left unfilled rather than given a neutral colour. "Nothing was
/// recorded" and "something was recorded and it was mild" are different facts about the user's
/// month and must not look alike, which is also why the empty cell is not simply the palest
/// green on the ramp.
///
/// **Colour is never the only channel** (`Palette.intensity`). The numeral stays in every
/// cell, the fill's opacity carries the same value as its hue so the grid still reads in
/// greyscale, and each recorded day exposes its actual figures to VoiceOver.
struct HistoryCalendarCard: View {

    let grid: MonthGrid

    /// Keyed by start of day, as `HistorySummary.days` is.
    let days: [Date: HistoryDay]

    let calendar: Calendar

    /// Blocked past the month containing today: a grid of empty future cells reads as data
    /// loss rather than as "not yet".
    let canGoForward: Bool

    /// Signed month step, run by the ‹ › buttons.
    let move: (Int) -> Void

    private enum Metrics {
        static let cornerRadius: CGFloat = 20
        static let borderWidth: CGFloat = 1
        static let padding: CGFloat = 17
        static let headerSpacing: CGFloat = 14
        static let columnSpacing: CGFloat = 4
        static let rowSpacing: CGFloat = 6
        static let cellHeight: CGFloat = 32
        static let arrowSide: CGFloat = 30
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Metrics.columnSpacing),
              count: grid.weekdays.count)
    }

    var body: some View {
        VStack(spacing: Metrics.headerSpacing) {
            header

            LazyVGrid(columns: columns, spacing: Metrics.rowSpacing) {
                ForEach(grid.weekdays, id: \.self) { weekday in
                    Text(verbatim: symbol(for: weekday))
                        .font(Typography.captionEmphasis)
                        .foregroundStyle(Palette.inkSubtle)
                        .frame(maxWidth: .infinity)
                }

                // Indexed because half the cells are padding and share the `nil` value, so
                // there is nothing in the element itself to identify it by.
                ForEach(Array(grid.cells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        DayCell(date: date,
                                day: days[calendar.startOfDay(for: date)],
                                isToday: calendar.isDateInToday(date),
                                calendar: calendar)
                        .frame(height: Metrics.cellHeight)
                    } else {
                        Color.clear.frame(height: Metrics.cellHeight)
                    }
                }
            }
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Palette.cardSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: Metrics.borderWidth)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            arrow(step: -1, systemName: "chevron.left", label: "Previous month")
                .accessibilitySortPriority(1)

            Text(verbatim: monthTitle)
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.heading)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
                .accessibilitySortPriority(2)

            arrow(step: 1, systemName: "chevron.right", label: "Next month")
                .disabled(!canGoForward)
                .opacity(canGoForward ? 1 : 0.35)
                .accessibilitySortPriority(0)
        }
    }

    private func arrow(step: Int, systemName: String, label: LocalizedStringKey) -> some View {
        Button {
            move(step)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.bodyText)
                .frame(width: Metrics.arrowSide, height: Metrics.arrowSide)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    /// "Травень 2026". Month and year are formatted separately and joined rather than asked
    /// for as one style: several languages — Ukrainian among them — decline the month name
    /// when it is followed by a day, and only the standalone form is a heading.
    private var monthTitle: String {
        let month = grid.month.formatted(.dateTime.month(.wide)).localizedCapitalized
        let year = grid.month.formatted(.dateTime.year())
        return "\(month) \(year)"
    }

    /// Ukrainian gives П В С Ч П С Н here, starting wherever `Calendar.firstWeekday` says.
    private func symbol(for weekday: Int) -> String {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "" }
        return symbols[weekday - 1]
    }
}

// MARK: - Day

/// One day of the grid.
private struct DayCell: View {

    let date: Date
    let day: HistoryDay?
    let isToday: Bool
    let calendar: Calendar

    private enum Metrics {
        static let radius: CGFloat = 9
        static let todayRing: CGFloat = 1.5
        /// Fill opacity at intensity 1 and at intensity 10. The low end stays visible against
        /// the card's white without shouting; the high end stops short of full so the numeral
        /// on top keeps its contrast.
        static let minimumFill: Double = 0.20
        static let maximumFill: Double = 0.92
    }

    var body: some View {
        Text(verbatim: date.formatted(.dateTime.day()))
            .font(Typography.choiceLabelCompact)
            .foregroundStyle(numeralColour)
            .monospacedDigit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .fill(fill)
            }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                        .strokeBorder(Palette.ink, lineWidth: Metrics.todayRing)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    private var fill: Color {
        guard let day else { return .clear }

        let position = day.peakIntensity.normalized
        let opacity = Metrics.minimumFill + (Metrics.maximumFill - Metrics.minimumFill) * position
        return Palette.intensity(day.peakIntensity).opacity(opacity)
    }

    /// Dark on every filled cell — the numeral never flips to light.
    ///
    /// Measured, not assumed. The ramp has no dark end: it runs green → amber → red, and the
    /// darkest fill this cell can take is `Palette.intensity(10)` at `maximumFill`, which
    /// composites to roughly `#D96858`. Against it `Palette.heading` gives about 4.7:1 and
    /// `Palette.onInk` about 3.7:1 — and at 13 pt semibold the numeral is not "large text", so
    /// 3.7 fails WCAG AA where 4.7 passes. Light text on the saturated end reads as the obvious
    /// choice and is the wrong one.
    private var numeralColour: Color {
        day == nil ? Palette.inkSubtle : Palette.heading
    }

    /// The date, then what was recorded — never a colour name. VoiceOver users get the figures
    /// the fill encodes, which is the only way this grid is readable without it.
    private var accessibilityLabel: Text {
        let day = date.formatted(.dateTime.weekday(.wide).day().month(.wide))

        guard let entry = self.day else {
            return Text("\(day). Nothing recorded")
        }

        let checkIns = Text("\(entry.checkInCount) check-ins")
        let intensity = Text("Peak intensity \(entry.peakIntensity.rawValue)")
        return Text(verbatim: "\(day). ") + checkIns + Text(verbatim: ". ") + intensity
    }
}

// MARK: - Preview

#Preview {
    let calendar = Calendar.current
    let now = Date.now
    let start = CheckInHistory.startOfMonth(containing: now, calendar: calendar)

    let recorded: [(Int, Int)] = [(1, 2), (2, 3), (4, 1), (5, 6), (6, 8), (7, 10), (10, 2), (12, 5)]
    let days = recorded.reduce(into: [Date: HistoryDay]()) { result, pair in
        guard let date = calendar.date(byAdding: .day, value: pair.0 - 1, to: start) else { return }
        result[date] = HistoryDay(date: date,
                                  checkInCount: 1,
                                  peakIntensity: CheckInIntensity(clamping: pair.1),
                                  medicationCount: 0)
    }

    return HistoryCalendarCard(grid: CheckInHistory.grid(forMonthContaining: now, calendar: calendar),
                               days: days,
                               calendar: calendar,
                               canGoForward: false,
                               move: { _ in })
        .padding(20)
        .background(Palette.surface)
}
