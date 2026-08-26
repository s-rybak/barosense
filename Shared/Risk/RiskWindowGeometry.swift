import Foundation

/// The waking day cut into fixed windows — the unit both stages of the risk model reason over.
///
/// ## Why a window and not a moment
///
/// A check-in happens at most once a day, against 96 quarter-hours of waking time. That is a
/// 0.8% positive class on ~90 events, which is not learnable. Aggregating into windows raises
/// the positive share in proportion to the width: at two hours it is ~11% of nine windows, and
/// the question changes from "which quarter-hour" — which nothing in the barometer can answer —
/// to "which stretch of the day", which it can.
///
/// Two hours is a product decision, not a modelling one. Measured across 30 min → 4 h the
/// ranking quality barely moves (ROC-AUC 0.764–0.799); what moves is the trade between how
/// often the named stretch contains the event and how much of the day it covers. Wider wins on
/// the first and loses on the second.
///
/// ## Why the night is cut out
///
/// It is a restriction of the domain, not a feature. Before the user wakes they cannot make an
/// entry, so a window there has a known answer and including it would hand the model free
/// accuracy on hours nobody was awake for. `dayStartHour` is therefore read from **when this
/// user's own earliest entry falls**, never from when entries are most frequent — the latter
/// would be a time-of-day feature smuggled in through the domain.
struct RiskWindowGeometry: Hashable, Sendable {

    /// Window width, minutes. See the type comment for why two hours.
    static let windowMinutes = 120

    /// Where the waking day starts when there is not enough history to read it off.
    ///
    /// 06:00. *Provisional* — it is the value the synthetic 120-day trace produced (earliest
    /// entry 07:00, less an hour of margin) and it is a plausible waking hour, but it is a
    /// guess about a person the app has not met yet.
    static let defaultDayStartHour = 6

    /// How many entries are needed before this user's own history overrides the default.
    ///
    /// Three, matching `CheckInRhythm`'s own floor: one early entry is an anecdote.
    static let minimumCheckInsForOwnStart = 3

    /// Where in the sorted entry hours the boundary is read off.
    ///
    /// **The 5th percentile, not the minimum.** The minimum is a one-sample estimator and this
    /// number sets the model's domain for the next 120 days: a single 00:30 entry drags the
    /// boundary to midnight, which turns a nine-window day into a twelve-window one, moves the
    /// base rate and `randomHitAtOne` with it, and scores the whole log against a domain the
    /// shipped coefficients were never fitted on. A fifth percentile keeps the "could an entry
    /// have happened here at all" reading — it still sits below all but a handful of entries —
    /// while costing one outlier its vote. Below ~20 entries it degrades to the minimum, which
    /// is the honest behaviour when there is no tail to trim.
    static let dayStartQuantile: Double = 0.05

    /// Margin below the earliest entry seen, hours.
    static let dayStartMarginHours = 1

    /// The boundary is never put later than this, however late this user's first entry is.
    ///
    /// Noon. Past it the waking day would be under twelve hours and the day-level features
    /// would be averaging half a day of weather under the name of a whole one.
    static let latestDayStartHour = 12

    /// Hour of the local day the waking window opens at.
    let dayStartHour: Int

    /// The calendar day boundaries are taken in. Threaded rather than read from `.current`, so
    /// a test can pin a time zone and the app can follow the language the user picked.
    let calendar: Calendar

    init(dayStartHour: Int = RiskWindowGeometry.defaultDayStartHour,
         calendar: Calendar = .current) {
        self.dayStartHour = min(max(dayStartHour, 0), Self.latestDayStartHour)
        self.calendar = calendar
    }

    var windowSeconds: TimeInterval { TimeInterval(Self.windowMinutes) * 60 }

    /// Windows in one waking day. Nine at the default boundary and the default width.
    ///
    /// Rounded down: a boundary that does not divide the remaining hours evenly loses the last
    /// part-window rather than drawing a short one, because a window narrower than the rest
    /// would carry a different base rate under the same name.
    var windowsPerDay: Int {
        max(1, (24 - dayStartHour) * 60 / Self.windowMinutes)
    }

    /// Start of the waking day the instant's **calendar day** belongs to.
    ///
    /// Note what this does at 03:00 with a 06:00 boundary: it returns 06:00 *today*, which is
    /// still ahead. That is deliberate — the forecast for "today" at three in the morning is a
    /// forecast for a day none of which has happened yet, and pushing it back to yesterday
    /// would forecast a day that is over.
    ///
    /// Built from the day's date components, so the boundary stays at `dayStartHour` on the
    /// **wall clock** through a DST transition instead of sliding to 05:00 or 07:00 for the day.
    /// Neither `startOfDay + dayStartHour * 3600` nor `date(byAdding: .hour,)` does that: both
    /// add elapsed time, and in Foundation only *date* units carry wall-clock arithmetic.
    ///
    /// The windows *inside* the day are still laid out in absolute hours from here, so on the
    /// two transition days a day is 23 or 25 hours long and its last window runs short or over.
    /// Accepted: a window is two hours of weather, and re-deriving each one through the calendar
    /// would cost nine conversions a day to move a boundary twice a year.
    func wakingDayStart(of instant: Date) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: instant)
        components.hour = dayStartHour

        return calendar.date(from: components)
            ?? calendar.startOfDay(for: instant)
                .addingTimeInterval(TimeInterval(dayStartHour) * 3600)
    }

    /// Whether the instant falls inside a waking day at all. False through the small hours.
    func isWaking(_ instant: Date) -> Bool {
        instant >= wakingDayStart(of: instant)
    }

    /// Every window start of the waking day containing `instant`, ascending.
    func windowStarts(ofDayContaining instant: Date) -> [Date] {
        let start = wakingDayStart(of: instant)
        return (0..<windowsPerDay).map { start.addingTimeInterval(Double($0) * windowSeconds) }
    }

    /// The window an instant falls in, or `nil` when it falls in the night the domain excludes.
    ///
    /// `nil` is not an error and is not rare — the model simply has nothing to say about an
    /// entry made at four in the morning, and dropping it is honest where assigning it to the
    /// first window of the day would put an event two hours from where it happened.
    func windowStart(containing instant: Date) -> Date? {
        let dayStart = wakingDayStart(of: instant)
        guard instant >= dayStart else { return nil }

        let index = Int(instant.timeIntervalSince(dayStart) / windowSeconds)
        guard index < windowsPerDay else { return nil }

        return dayStart.addingTimeInterval(Double(index) * windowSeconds)
    }

    /// The geometry this user's own history implies.
    ///
    /// **Early, not mode.** The boundary answers "could an entry have happened here at all",
    /// so it is read off the early tail of the entry hours — see `dayStartQuantile` for why
    /// that is a low percentile rather than the outright minimum. Taking the most common hour
    /// instead would encode a habit, and a habit is a time-of-day feature — measured separately
    /// and left out of the model on purpose, because on its own it ranks windows barely better
    /// than a coin (ROC-AUC 0.583) and adds nothing on top of pressure.
    static func measured(from checkIns: [CheckIn],
                         calendar: Calendar = .current) -> RiskWindowGeometry {
        guard checkIns.count >= minimumCheckInsForOwnStart else {
            return RiskWindowGeometry(dayStartHour: defaultDayStartHour, calendar: calendar)
        }

        let hours = checkIns.map { calendar.component(.hour, from: $0.timestamp) }.sorted()
        let index = Int((Double(hours.count - 1) * dayStartQuantile).rounded(.down))
        guard hours.indices.contains(index) else {
            return RiskWindowGeometry(dayStartHour: defaultDayStartHour, calendar: calendar)
        }
        let earliest = hours[index]

        return RiskWindowGeometry(dayStartHour: earliest - dayStartMarginHours,
                                  calendar: calendar)
    }
}
