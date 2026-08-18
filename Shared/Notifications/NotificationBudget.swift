import Foundation

<<<<<<< HEAD
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
=======
/// How much of one day's notification allowance is spent.
///
/// The value the Settings section prints and the value dispatch gates on — one type, so the
/// number the user reads is the number the app enforces rather than a second count that
/// agrees with it by coincidence.
struct NotificationBudgetStatus: Hashable, Sendable {

    /// Start of the day this describes, in the calendar it was computed with.
    let day: Date

    /// Rows already scheduled or delivered for that day.
    let used: Int

    let limit: Int

    /// Never negative. A day can overrun its limit — the ceiling was lowered, or the clock
    /// moved — and reporting "−1 left" would be arithmetic rather than an answer.
    var remaining: Int { max(limit - used, 0) }

    var hasRoom: Bool { remaining > 0 }
}

/// The cap on how many notifications Barosense may send in one day.
///
/// Three, and the number lives here alone. It is a product rule, not a technical one: the app
/// asks the user a question about themselves, and an app that asks too often gets its
/// notifications turned off entirely — after which nothing it has to say arrives at all.
///
/// Counted over the log rather than over anything the system knows, for the reason the log
/// exists: `UNUserNotificationCenter` reports what is pending, forgets what it has delivered
/// once the user clears it, and cannot be asked "how many did you send yesterday". The rows
/// can answer both.
///
/// Pure arithmetic over values, with the `Calendar` passed in. A day boundary is a calendar
/// question — it moves with the time zone, and it is not 24 hours long twice a year — so a
/// test can pin one instead of passing under the device's and failing under another.
enum NotificationBudget {

    /// The most notifications Barosense will send in one calendar day, across every kind.
    ///
    /// One budget for all kinds rather than one per kind: the user experiences the total, and
    /// a per-kind allowance is how three quiet features add up to nine interruptions.
    static let dailyLimit = 3

    /// What is left of `day`'s allowance, given the whole log for it.
    ///
    /// `log` may contain rows for other days; they are filtered here rather than at the call
    /// site, so a caller cannot spend the budget of a day it did not mean to.
    static func status(on day: Date,
                       log: [AppNotification],
                       limit: Int = dailyLimit,
                       calendar: Calendar = .current) -> NotificationBudgetStatus {
        let start = calendar.startOfDay(for: day)
        let used = log.count(where: { notification in
            notification.state.consumesBudget
                && calendar.isDate(notification.scheduledFor, inSameDayAs: start)
        })

        return NotificationBudgetStatus(day: start, used: used, limit: limit)
    }

    /// Whether one more notification may go out on the day containing `date`.
    static func hasRoom(on date: Date,
                        log: [AppNotification],
                        limit: Int = dailyLimit,
                        calendar: Calendar = .current) -> Bool {
        status(on: date, log: log, limit: limit, calendar: calendar).hasRoom
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)
    }
}
