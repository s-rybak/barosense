import Foundation

/// How many notifications Barosense will put in front of the user in one day.
///
/// **Three, counted per local calendar day, across every kind.** Not three reminders plus three
/// forecast warnings: the number the user experiences is the total, and a cap that were per-kind
/// would grow every time a kind was added — which is the failure mode of every app that ends up
/// notifying six times a day without anyone having decided to.
///
/// Three is a judgement, not a measurement. The reasoning: the reminder this app sends is worth
/// exactly one interruption a day, and the forecast warning `CLAUDE.md` describes is worth at
/// most one more, which leaves one for a day when the weather moves twice. A fourth would have
/// to displace one of those, and there is no notification here important enough to argue for it.
/// Whatever the right number is, the point is that it is decided in one place and enforced
/// against the stored log rather than re-derived at each call site.
///
/// The count is over stored rows, not over what this process has sent, so it survives a relaunch:
/// two notifications scheduled yesterday evening for this morning are already spent when the app
/// opens at noon.
struct NotificationBudget: Sendable {

    /// The shipped cap.
    static let dailySendLimit = 3

    let dailySendLimit: Int

    init(dailySendLimit: Int = Self.dailySendLimit) {
        self.dailySendLimit = dailySendLimit
    }

    /// The half-open day `date` falls in, in `calendar`.
    ///
    /// The user's own local day, not a rolling 24 hours. "Three a day" is a promise about waking
    /// up to a fresh allowance; a rolling window would make yesterday's late notification eat
    /// into this morning, which is not what the sentence means. A day the calendar will not
    /// resolve an end for falls back to the instant itself, which spends nothing and is visible
    /// rather than silently permissive.
    func day(containing date: Date, calendar: Calendar) -> Range<Date> {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start), end > start else {
            return start..<start.addingTimeInterval(1)
        }

        return start..<end
    }

    /// How many of the day's sends the records already account for.
    ///
    /// `records` may be any window — `day(containing:calendar:)` is what narrows it, and rows
    /// outside that day are ignored rather than trusted, so a caller that passes a wider window
    /// gets the right answer instead of an inflated one.
    ///
    /// Not clamped to the cap. This is what the Settings row reports, and a day that somehow
    /// holds four rows should read as four rather than be rounded down to the promise — the
    /// number is there to be checked against, so it has to be able to disagree.
    func spentSends(on date: Date,
                    given records: [NotificationRecord],
                    calendar: Calendar) -> Int {
        let window = day(containing: date, calendar: calendar)

        return records
            .filter { window.contains($0.scheduledFor) && $0.state.spendsAllowance }
            .count
    }

    /// How many sends are left on the day containing `date`, given every record already logged
    /// against it.
    ///
    /// Never negative. A day already over its allowance — possible only if the cap were lowered
    /// in an update while rows were in flight — reports zero rather than a negative number that
    /// arithmetic elsewhere would have to remember to clamp.
    func remainingSends(on date: Date,
                        given records: [NotificationRecord],
                        calendar: Calendar) -> Int {
        max(0, dailySendLimit - spentSends(on: date, given: records, calendar: calendar))
    }

    /// Whether one more notification may be placed on the day containing `date`.
    func admitsAnotherSend(on date: Date,
                           given records: [NotificationRecord],
                           calendar: Calendar) -> Bool {
        remainingSends(on: date, given: records, calendar: calendar) > 0
    }
}
