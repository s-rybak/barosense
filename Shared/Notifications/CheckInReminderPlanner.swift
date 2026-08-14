import Foundation

/// When the "How are you feeling?" reminder should land, for the next few days.
///
/// Pure arithmetic over a clock reading and a calendar — no store, no notification centre, no
/// clock of its own. What it returns is a *wish list*; whether any of it is actually sent is
/// `NotificationDispatcher`'s decision, and it is bounded by `NotificationBudget`.
///
/// ## Why several days at once
///
/// Nothing here runs in the background. The app plans when it is opened, so a plan one slot deep
/// would stop the day the user did not open it — which is exactly the day a reminder was worth
/// sending. A week of slots is handed to the system in one pass and re-reconciled on the next
/// activation. It costs nothing to keep: `UNUserNotificationCenter` holds up to 64 pending
/// requests per app, seven is well inside that, and a scheduled request draws no power until it
/// fires.
struct CheckInReminderPlanner: Sendable {

    /// The user's own logging time, when there is a dependable reading of one. `nil` on a fresh
    /// install and on scattered histories alike — see `CheckInRhythm.isDependable`.
    let rhythm: CheckInRhythm?

    let calendar: Calendar

    /// Kill switch for the whole reminder, in the same shape as
    /// `PressureSamplingPolicy.isBackgroundRefreshEnabled`.
    ///
    /// Off, this plans nothing; the dispatcher then withdraws whatever is outstanding on the
    /// next activation, because an empty plan is a plan that wants none of it. Turning the
    /// feature off is therefore a one-constant change that also cleans up after itself, without
    /// a release having to remove code.
    static let isEnabled = true

    /// Where the reminder goes when the rhythm cannot say.
    ///
    /// 20:00: late enough that the day being asked about has happened, early enough not to land
    /// in most people's sleep. It is a placeholder for a reading, not a recommendation, and it is
    /// replaced by the user's own time as soon as three check-ins exist.
    static let fallbackMinuteOfDay = 20 * 60

    /// How many daily slots one plan covers.
    static let horizonDays = 7

    /// Nothing is scheduled closer than this to now.
    ///
    /// A trigger a few seconds out either fires while the user is still holding the phone — the
    /// one moment a reminder to open the app is pure noise — or is missed entirely because the
    /// app was foregrounded past it. Five minutes is enough to be sure the user has put the
    /// phone down.
    static let minimumLead: TimeInterval = 5 * 60

    /// The minute of the day the reminder is placed at.
    var minuteOfDay: Int {
        guard let rhythm, rhythm.isDependable else { return Self.fallbackMinuteOfDay }

        return rhythm.minuteOfDay
    }

    /// The slots to ask for, ascending, starting from the first one that is still worth having.
    ///
    /// `lastCheckIn` suppresses the slot on a day the user has already logged: a reminder to
    /// check in, sent hours after they checked in, is the app failing to notice that it got what
    /// it asked for. Only the first slot can ever be affected — later days have no check-ins in
    /// them yet — but the rule is written over every slot rather than special-cased on the first,
    /// so a plan built from a stale clock cannot slip past it.
    func slots(from now: Date,
               lastCheckIn: Date?,
               horizonDays: Int = Self.horizonDays) -> [Date] {
        let earliest = now.addingTimeInterval(Self.minimumLead)
        let today = calendar.startOfDay(for: now)

        // One extra day is walked so that a plan starting tomorrow still returns `horizonDays`
        // slots rather than one short.
        let walked = (0...horizonDays).compactMap { offset -> Date? in
            // `bySettingHour` rather than adding `minuteOfDay` minutes to midnight. The two
            // differ on the two days a year a time zone changes offset: adding 1200 minutes to
            // a 23-hour day lands at 21:00, and this reminder is placed at a wall-clock time the
            // user recognises, not at an elapsed duration since midnight.
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let slot = calendar.date(bySettingHour: minuteOfDay / 60,
                                           minute: minuteOfDay % 60,
                                           second: 0,
                                           of: day),
                  slot >= earliest,
                  !alreadyLogged(on: slot, lastCheckIn: lastCheckIn)
            else {
                return nil
            }

            return slot
        }

        return Array(walked.prefix(horizonDays))
    }

    private func alreadyLogged(on slot: Date, lastCheckIn: Date?) -> Bool {
        guard let lastCheckIn else { return false }

        return calendar.isDate(lastCheckIn, inSameDayAs: slot)
    }
}
