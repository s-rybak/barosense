import Foundation

/// How far back a shareable report reaches.
///
/// Four options, and deliberately **not** `HistoryPeriod`. That one covers whole calendar
/// months ending with the month the History grid is showing, because its whole job is to
/// keep the counts card and the grid describing the same stretch of time. A report has no
/// grid to agree with: the reader asked for "the last three months" and expects the window
/// to end today, not at the end of whichever month they last scrolled to. Two different
/// questions, two types — folding them together would make one of the two screens lie.
///
/// Raw values are not persisted anywhere today. They exist so the selection survives a
/// future move into storage without renumbering.
enum ReportPeriod: String, CaseIterable, Identifiable, Sendable {
    case oneMonth
    case threeMonths
    case sixMonths
    case twelveMonths

    var id: String { rawValue }

    /// Whole months the window spans.
    var months: Int {
        switch self {
        case .oneMonth: 1
        case .threeMonths: 3
        case .sixMonths: 6
        case .twelveMonths: 12
        }
    }

    /// The default a freshly opened report screen offers.
    ///
    /// Three months rather than one: the report exists to be handed to someone who has not
    /// been watching the log accumulate, and a single month of an app that only asks for a
    /// check-in when something is worth reporting can come out nearly empty.
    static let `default` = ReportPeriod.threeMonths
}

extension ReportPeriod {

    /// The half-open range the report covers, ending at the end of the day containing `now`.
    ///
    /// Whole days at both ends. A window running from "this instant minus three months" would
    /// cut today's morning check-in out of a report generated in the afternoon, and the header
    /// would still print today's date — a document that silently omits the day it names is
    /// worse than one that names a wider window.
    ///
    /// Half-open at the start of tomorrow, matching `CheckInStore.checkIns(in:)`, so a
    /// check-in written a second before midnight is inside and one written a second after is
    /// not.
    ///
    /// A calendar the caller supplies rather than `.current`: the boundaries are day
    /// boundaries, which depend on the time zone, and a test has to be able to pin one.
    func window(endingOn now: Date, calendar: Calendar = .current) -> Range<Date> {
        let startOfToday = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let start = calendar.date(byAdding: .month, value: -months, to: startOfToday) ?? startOfToday

        // Guards against a calendar that will not do the arithmetic, which would otherwise
        // produce an empty or inverted range and a report that silently holds nothing.
        return min(start, startOfToday)..<end
    }

    /// The last day the window actually covers — its upper bound is the start of the next day.
    ///
    /// What the header prints. Formatting `window.upperBound` would name tomorrow.
    func lastCoveredDay(endingOn now: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }
}
