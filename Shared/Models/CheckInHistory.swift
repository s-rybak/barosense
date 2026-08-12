import Foundation

/// How far back the History screen counts (Figma `M3 · Історія`).
///
/// Every option is a span of whole calendar months **ending with the month the grid is
/// showing**, not a trailing window from today. That is what keeps the ‹ › arrows honest: they
/// move the grid and the counts card together, so the card never describes a window the user
/// is not looking at.
enum HistoryPeriod: String, CaseIterable, Identifiable, Sendable {
    case month
    case threeMonths
    case year
    case all

    var id: String { rawValue }

    /// Whole months in the window, the anchor month included. `nil` for `.all`, which has no
    /// start at all.
    var monthSpan: Int? {
        switch self {
        case .month: 1
        case .threeMonths: 3
        case .year: 12
        case .all: nil
        }
    }
}

/// One day of the calendar grid, as the check-ins recorded in it leave it.
struct HistoryDay: Identifiable, Hashable, Sendable {

    /// Start of the day, in the calendar the summary was built with.
    let date: Date

    let checkInCount: Int

    /// The **highest** intensity reported that day, not the mean.
    ///
    /// Averaging is the wrong summary for this grid. A day holding one 9 and two 2s averages
    /// to 4 and draws green, which hides exactly the day the user opened the calendar to
    /// find. The colour answers "was there a bad hour here", and only the peak can.
    let peakIntensity: CheckInIntensity

    /// Entries across every check-in that day — one per thing taken, so taking the same thing
    /// twice counts twice.
    let medicationCount: Int

    var id: Date { date }
}

/// One tag and how many check-ins in the window carried it.
///
/// Identity, not text: the tag vocabulary is user-owned and renameable, so a count keyed on
/// the word would split the moment somebody edits it.
struct HistoryTagCount: Identifiable, Hashable, Sendable {
    let id: WellbeingTag.ID
    let count: Int
}

/// What the History screen prints above its grid: how much was recorded in the window, what
/// it was tagged with, and how much was taken.
///
/// Counts only. Nothing here ranks days, scores a period, or compares one window to another —
/// this is the user's own log added up, and it stays that.
struct HistorySummary: Hashable, Sendable {

    let checkInCount: Int

    /// Descending by count. Ties are broken deterministically so the two tags the card shows
    /// do not swap places between two builds of the same data.
    let tagCounts: [HistoryTagCount]

    let medicationCount: Int

    /// Keyed by start of day, so the grid looks up a cell without scanning.
    let days: [Date: HistoryDay]

    static let empty = HistorySummary(checkInCount: 0,
                                      tagCounts: [],
                                      medicationCount: 0,
                                      days: [:])
}

/// The cells of one month, in reading order.
struct MonthGrid: Hashable, Sendable {

    /// Start of the month drawn.
    let month: Date

    /// `Calendar` weekday numbers (1–7) in the order the header prints them, which is the
    /// order the cells run in. Derived from the calendar's own `firstWeekday`, so a Ukrainian
    /// locale starts on Monday and a US one on Sunday without either being hard-coded.
    let weekdays: [Int]

    /// One entry per cell, padded to whole weeks. `nil` is a blank before the first or after
    /// the last of the month.
    let cells: [Date?]
}

/// Turning a list of check-ins into what the History screen draws.
///
/// Pure calendar arithmetic and counting — no store, no clock of its own, no view. Every
/// function takes the `Calendar` it should work in rather than reaching for `.current`
/// internally, so a test can pin a time zone and a first weekday instead of passing under one
/// and failing under another.
enum CheckInHistory {

    // MARK: - Window

    /// The half-open range a period covers, anchored on the month containing `date`.
    ///
    /// Half-open at the start of the *next* month, matching `CheckInStore.checkIns(in:)`: two
    /// adjacent windows can be asked for without the boundary check-in landing in both.
    static func window(for period: HistoryPeriod,
                       anchoredOn date: Date,
                       calendar: Calendar = .current) -> Range<Date> {
        let start = startOfMonth(containing: date, calendar: calendar)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date

        guard let span = period.monthSpan else { return Date.distantPast..<end }

        let lower = calendar.date(byAdding: .month, value: -(span - 1), to: start) ?? start
        return lower..<end
    }

    /// The month `offset` months from the one containing `date`. The ‹ › arrows.
    static func month(offsetBy offset: Int,
                      from date: Date,
                      calendar: Calendar = .current) -> Date {
        let start = startOfMonth(containing: date, calendar: calendar)
        return calendar.date(byAdding: .month, value: offset, to: start) ?? start
    }

    // MARK: - Grid

    /// The grid for the month containing `date`.
    ///
    /// A month whose day range the calendar will not report comes back with no cells rather
    /// than with a guessed layout — an empty grid is visibly empty, a wrong one is not.
    static func grid(forMonthContaining date: Date, calendar: Calendar = .current) -> MonthGrid {
        let start = startOfMonth(containing: date, calendar: calendar)
        let weekdays = orderedWeekdays(calendar: calendar)

        guard let dayCount = calendar.range(of: .day, in: .month, for: start)?.count else {
            return MonthGrid(month: start, weekdays: weekdays, cells: [])
        }

        let firstWeekday = calendar.component(.weekday, from: start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: start))
        }

        let remainder = cells.count % 7
        if remainder != 0 {
            cells.append(contentsOf: Array(repeating: nil, count: 7 - remainder))
        }

        return MonthGrid(month: start, weekdays: weekdays, cells: cells)
    }

    // MARK: - Counting

    /// Everything the summary card and the grid read, from one pass over the window.
    static func summary(of checkIns: [CheckIn], calendar: Calendar = .current) -> HistorySummary {
        guard !checkIns.isEmpty else { return .empty }

        var tagCounts: [WellbeingTag.ID: Int] = [:]
        var medicationCount = 0
        var days: [Date: HistoryDay] = [:]

        for checkIn in checkIns {
            for tagID in checkIn.tagIDs {
                tagCounts[tagID, default: 0] += 1
            }
            medicationCount += checkIn.medications.count

            let day = calendar.startOfDay(for: checkIn.timestamp)
            days[day] = merge(checkIn, into: days[day], on: day)
        }

        return HistorySummary(checkInCount: checkIns.count,
                              tagCounts: ranked(tagCounts),
                              medicationCount: medicationCount,
                              days: days)
    }

    private static func merge(_ checkIn: CheckIn, into existing: HistoryDay?, on day: Date) -> HistoryDay {
        guard let existing else {
            return HistoryDay(date: day,
                              checkInCount: 1,
                              peakIntensity: checkIn.intensity,
                              medicationCount: checkIn.medications.count)
        }

        return HistoryDay(date: day,
                          checkInCount: existing.checkInCount + 1,
                          peakIntensity: max(existing.peakIntensity, checkIn.intensity),
                          medicationCount: existing.medicationCount + checkIn.medications.count)
    }

    /// Most-used first. Equal counts fall back to a stable key rather than to whatever order
    /// the dictionary happened to enumerate in — the card shows the top two, and two tags used
    /// the same number of times must not trade places on a redraw.
    private static func ranked(_ counts: [WellbeingTag.ID: Int]) -> [HistoryTagCount] {
        counts
            .map { HistoryTagCount(id: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? sortKey(lhs.id) < sortKey(rhs.id) : lhs.count > rhs.count
            }
    }

    /// A total order over tag identity, for tie-breaking only.
    ///
    /// Deliberately not `StoredWellbeingTag.identityKey(for:)`: that string is a storage
    /// format and must be free to change without silently reordering a screen.
    private static func sortKey(_ id: WellbeingTag.ID) -> String {
        switch id {
        case .seeded(let slug): "0\(slug)"
        case .user(let uuid): "1\(uuid.uuidString)"
        }
    }

    // MARK: - Calendar helpers

    static func startOfMonth(containing date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    /// The seven weekday numbers starting at the calendar's own first weekday.
    private static func orderedWeekdays(calendar: Calendar) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }
}
