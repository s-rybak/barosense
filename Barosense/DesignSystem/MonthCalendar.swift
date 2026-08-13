import SwiftUI

/// The month grid, and everything above it: ‹ ›, the month title that opens a month/year wheel
/// behind it, "Now", the weekday letters, and the cells laid out in reading order.
///
/// One component rather than one per screen. The History grid and the day picker on the
/// medication sheet are the same calendar asked two different questions — which day has
/// something recorded on it, and which day is this entry filed under — and the *navigation* is
/// identical in both: the same months are reachable, the same ones are not, the same wheels open
/// behind the same title. Two implementations of that is two places for "the future is not
/// reachable" to be decided, and they had already drifted: the sheet shipped a
/// `DatePicker(.graphical)`, which draws a different header, a different week start under some
/// locales, and no way back to today.
///
/// Generic over the cell because that is the only part that legitimately differs — History fills
/// a day with the intensity recorded on it, the picker marks the one the user chose. Everything
/// else, including the cell's height, is decided here so the two grids cannot drift again.
///
/// Chrome-free on purpose: `HistoryCalendarCard` wraps this in the card the design draws, the
/// sheet does not. A component that drew its own border could only be used in one of the two.
struct MonthCalendar<Cell: View>: View {

    /// The month on screen. Owned by the caller, because moving it is what re-queries the store
    /// on History and what nothing at all does on the sheet.
    let grid: MonthGrid

    /// The app's language travels on this — see `LanguageController.calendar`. It supplies the
    /// month names, the weekday letters and `firstWeekday`, none of which a `Locale` carries.
    let calendar: Calendar

    /// Start of the month containing the last reachable day. Nothing after it can be reached —
    /// a grid of empty future cells reads as data loss rather than as "not yet" — so this bounds
    /// the › arrow and the wheels alike, and says whether "Now" has anywhere to go.
    let currentMonth: Date

    /// Signed month step, run by the ‹ › buttons.
    let move: (Int) -> Void

    /// Jump straight to a month, run by the two wheels behind the title. Implementations clamp
    /// to `currentMonth`; the wheels rely on that rather than filtering twice.
    let select: (_ month: Int, _ year: Int) -> Void

    /// One day of the month. Never called for a padding cell — those are blank by definition and
    /// giving a caller the chance to draw something in them is how a grid gains a 32nd of March.
    @ViewBuilder let cell: (Date) -> Cell

    enum Metrics {
        static var headerSpacing: CGFloat { 14 }
        static var columnSpacing: CGFloat { 4 }
        static var rowSpacing: CGFloat { 6 }
        static var cellHeight: CGFloat { 32 }
        static var arrowSide: CGFloat { 30 }
        /// `WheelColumn.standardHeight`, not a shorter figure trimmed to leave the grid below
        /// more room. A wheel is laid out in whole rows: at 132 pt the row above and the row
        /// below the selection were each cut in half by the frame, and a half-height month
        /// name behind the picker's own fade reads as a rendering fault rather than as the
        /// next month along. Both callers are inside a `ScrollView`; 28 pt is cheaper than that.
        static var wheelHeight: CGFloat { WheelColumn<Int>.standardHeight }
        static var reveal: Animation { .snappy(duration: 0.24) }
    }

    /// Whether the wheels are showing. View state rather than the caller's: which control is
    /// open is not part of what either screen is looking at, and folding it into History's query
    /// would re-read the store on a disclosure.
    @State private var isPickingMonth = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Metrics.columnSpacing),
              count: grid.weekdays.count)
    }

    /// The only fact the ›, the wheels and "Now" all need: the last reachable day is in a later
    /// month than the one on screen.
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
                        cell(date)
                            .frame(height: Metrics.cellHeight)
                    } else {
                        Color.clear.frame(height: Metrics.cellHeight)
                    }
                }
            }
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
    /// Navigation only — it never picks a day. On the medication sheet that distinction matters:
    /// the sheet is recording when a dose was taken, and a control that quietly moved the answer
    /// to today while the user was looking for a day in it would file the entry against the
    /// wrong one. The same rule the "Other day" chip follows when it opens.
    ///
    /// Dimmed rather than removed when it is already showing — drawn exactly as the › arrow
    /// beside it is, and for the same reason: a control that disappears takes its own
    /// explanation with it.
    private var nowButton: some View {
        Button {
            withAnimation(Metrics.reveal) { isPickingMonth = false }
            // Expressed as a pick rather than as a step, because a step needs to know how far
            // it is back to today and this view only knows which month that is. `select`
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
    /// Live rather than behind a "Done": each stop on a wheel moves the grid below, so the user
    /// sees what they picked without committing to it. That is also why the wheels sit above the
    /// grid instead of replacing it.
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

    /// The language the calendar speaks — the app's, not the device's. See
    /// `LanguageController.calendar`: the month and weekday symbols below come out of it,
    /// and a bare `.formatted()` beside them would resolve through `Locale.current` and
    /// print the launch language instead.
    private var locale: Locale { calendar.locale ?? .current }

    /// "Травень", not "травня" — the standalone form, for the same reason `monthTitle` asks for
    /// it: a wheel row names the month rather than dating something within it.
    private func monthName(_ month: Int) -> String {
        let symbols = calendar.standaloneMonthSymbols
        guard symbols.indices.contains(month - 1) else { return String(month) }

        return symbols[month - 1].capitalized(with: locale)
    }

    /// "Травень 2026". Month and year are formatted separately and joined rather than asked
    /// for as one style: several languages — Ukrainian among them — decline the month name
    /// when it is followed by a day, and only the standalone form is a heading.
    private var monthTitle: String {
        let month = grid.month.formatted(.dateTime.month(.wide).locale(locale))
        let year = grid.month.formatted(.dateTime.year().locale(locale))
        return "\(month.capitalized(with: locale)) \(year)"
    }

    /// Ukrainian gives П В С Ч П С Н here, starting wherever `Calendar.firstWeekday` says.
    private func symbol(for weekday: Int) -> String {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "" }
        return symbols[weekday - 1]
    }
}
