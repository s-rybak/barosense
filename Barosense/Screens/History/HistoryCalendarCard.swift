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

    /// Start of the month containing today. Nothing after it is reachable — a grid of empty
    /// future cells reads as data loss rather than as "not yet" — so this bounds the ›
    /// arrow and the picker alike, and says whether "Now" has anywhere to go.
    let currentMonth: Date

    /// Signed month step, run by the ‹ › buttons.
    let move: (Int) -> Void

    /// Jump straight to a month, run by the two wheels behind the title.
    let select: (_ month: Int, _ year: Int) -> Void

    private enum Metrics {
        static let cornerRadius: CGFloat = 20
        static let borderWidth: CGFloat = 1
        static let padding: CGFloat = 17
        static let headerSpacing: CGFloat = 14
        static let columnSpacing: CGFloat = 4
        static let rowSpacing: CGFloat = 6
        static let cellHeight: CGFloat = 32
        static let arrowSide: CGFloat = 30
        /// Shorter than `WheelColumn.standardHeight`: this wheel sits *above* a six-row grid
        /// rather than at the bottom of a sheet, and the card still has to fit a small screen
        /// with both open.
        static let wheelHeight: CGFloat = 132
        static let reveal = Animation.snappy(duration: 0.24)
    }

    /// Whether the wheels are showing. Card state rather than the model's: which control is
    /// open is not part of what the History screen is looking at, and folding it into the
    /// query would re-read the store on a disclosure.
    @State private var isPickingMonth = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Metrics.columnSpacing),
              count: grid.weekdays.count)
    }

    /// The only fact the ›, the picker and "Now" all need: today is in a later month than the
    /// one on screen.
    private var isBeforeCurrentMonth: Bool { grid.month < currentMonth }

    var body: some View {
        VStack(spacing: Metrics.headerSpacing) {
            header

            if isPickingMonth {
                monthWheels
                    // Fades and slides rather than appearing: the grid below moves down by the
                    // wheel's height, and an instant jump reads as the card being replaced.
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
                .accessibilitySortPriority(3)

            title
                .frame(maxWidth: .infinity)
                .accessibilitySortPriority(2)

            arrow(step: 1, systemName: "chevron.right", label: "Next month")
                .disabled(!isBeforeCurrentMonth)
                .opacity(isBeforeCurrentMonth ? 1 : 0.35)
                .accessibilitySortPriority(1)

            nowButton
                .accessibilitySortPriority(0)
        }
    }

    /// The month name, and the way into the wheels under it.
    ///
    /// The title was already the header's centre of gravity, so it is the control rather than a
    /// separate button beside it — a row of ‹ › plus a title plus two more controls does not
    /// fit the card at an accessibility type size. The chevron is what says it opens.
    private var title: some View {
        Button {
            withAnimation(Metrics.reveal) { isPickingMonth.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: monthTitle)
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.heading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.inkSubtle)
                    .rotationEffect(.degrees(isPickingMonth ? 180 : 0))
            }
            .frame(height: Metrics.arrowSide)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: monthTitle))
        .accessibilityHint(Text("Choose month and year"))
        .accessibilityAddTraits(isPickingMonth ? [.isHeader, .isSelected] : .isHeader)
    }

    /// Back to the month containing today.
    ///
    /// Dimmed rather than removed when it is already showing — drawn exactly as the › arrow
    /// beside it is, and for the same reason: a control that disappears takes its own
    /// explanation with it.
    private var nowButton: some View {
        Button {
            withAnimation(Metrics.reveal) { isPickingMonth = false }
            // Expressed as a pick rather than as a step, because a step needs to know how far
            // it is back to today and this card only knows which month that is. `select`
            // already clamps to exactly this month, so the two cannot disagree.
            select(calendar.component(.month, from: currentMonth),
                   calendar.component(.year, from: currentMonth))
        } label: {
            Text("Now")
                .font(Typography.captionEmphasis)
                .foregroundStyle(Palette.bodyText)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: Metrics.arrowSide)
                .background {
                    Capsule().fill(Palette.segmentedTrack)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isBeforeCurrentMonth)
        .opacity(isBeforeCurrentMonth ? 1 : 0.35)
        .accessibilityLabel(Text("Current month"))
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

    // MARK: - Month and year wheels

    /// Two columns behind the title: the months of the shown year, and the years on offer.
    ///
    /// Live rather than behind a "Done": each stop on a wheel moves the grid below and the
    /// counts card above, so the user sees what they picked without committing to it. That is
    /// also why the wheels sit above the grid instead of replacing it.
    private var monthWheels: some View {
        HStack(spacing: 0) {
            WheelColumn(selection: monthSelection, values: selectableMonths) {
                Text(verbatim: monthName($0))
            }

            WheelColumn(selection: yearSelection, values: offeredYears) {
                // `verbatim` and no grouping separator: 2026 is a year, not a quantity, and
                // `.formatted()` would print "2 026" on several locales.
                Text(verbatim: String($0))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.wheelHeight)
    }

    private var offeredYears: [Int] {
        CheckInHistory.offeredYears(notAfter: currentMonth, calendar: calendar)
    }

    /// Short of twelve in the current year — see `CheckInHistory.selectableMonths`. Read from
    /// the *shown* year, so stepping the year wheel onto this one trims the month column with
    /// it rather than leaving unreachable rows on the wheel.
    private var selectableMonths: [Int] {
        CheckInHistory.selectableMonths(in: shownYear, notAfter: currentMonth, calendar: calendar)
    }

    private var shownMonth: Int { calendar.component(.month, from: grid.month) }

    private var shownYear: Int { calendar.component(.year, from: grid.month) }

    /// Read straight off `grid.month` rather than mirrored into `@State`: a local copy of the
    /// selection is a second answer that can disagree with the month actually being drawn — and
    /// it is what makes the clamp visible when a year change puts the month in the future, since
    /// the wheel then snaps to where the grid went.
    private var monthSelection: Binding<Int> {
        Binding(get: { shownMonth }, set: { select($0, shownYear) })
    }

    private var yearSelection: Binding<Int> {
        Binding(get: { shownYear }, set: { select(shownMonth, $0) })
    }

    /// "Травень", not "травня" — the standalone form, for the same reason `monthTitle` asks for
    /// it: a wheel row names the month rather than dating something within it.
    private func monthName(_ month: Int) -> String {
        let symbols = calendar.standaloneMonthSymbols
        guard symbols.indices.contains(month - 1) else { return String(month) }

        return symbols[month - 1].localizedCapitalized
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
                               currentMonth: start,
                               move: { _ in },
                               select: { _, _ in })
        .padding(20)
        .background(Palette.surface)
}
