import Foundation

/// How many WeatherKit requests Barosense will make in a day, and when they become allowed.
///
/// ## Slots, not a timer
///
/// `BGAppRefreshTask.earliestBeginDate` is a floor, never a schedule: iOS grants wakes from
/// usage history and throttles them hard in Low Power Mode, so an app that asked for a request
/// "every four hours" would get an unpredictable number of them. What this type defines
/// instead is **four moments a day at which a request becomes permitted**. Whichever execution
/// the app is next granted — a background wake or the user opening the app — spends the slot
/// that is due, and an unspent slot is simply not spent.
///
/// That inverts the usual failure. A timer that does not fire loses a refresh; a slot that has
/// not been spent stays due, so the first activation of the afternoon collects the morning's.
///
/// ## The count comes off the store
///
/// `NotificationBudget`'s mechanic, for its reason: a counter in memory resets with the
/// process, and a phone that relaunches six times a day would make four requests each time.
/// The number of **issues** already archived for the local day is the count, so it survives a
/// relaunch and can be checked against the rows.
///
/// ## Cost
///
/// Four requests a day is 120 a month per device. Against the 500 000/month that comes with an
/// Apple Developer Program membership that is **~4 160 devices**, and the real figure is lower
/// because unspent slots are never spent. The quota belongs to the whole membership rather
/// than to this app, so it is worth re-checking before the install base gets anywhere near it.
struct WeatherRequestBudget: Sendable {

    /// The shipped cap.
    ///
    /// Four. Pressure changes on a synoptic timescale — a front takes hours to cross — so the
    /// interesting quantity is a curve refreshed a few times a day, not a live feed. The
    /// number is a quota and battery decision, and it is enforced against stored rows rather
    /// than trusted.
    static let dailyRequestLimit = 4

    /// The three slots that do not move.
    ///
    /// Local wall-clock hours, spread across the waking day so a curve is never much more than
    /// four hours old while the user is awake.
    static let fixedSlotHours = [12, 16, 20]

    /// The first slot when nothing is known about when the user wakes.
    static let fallbackFirstSlotHour = 8

    /// Bounds on where the wake-derived first slot may land.
    ///
    /// A single odd night — a flight, a newborn, a sleep sample Health recorded badly — must
    /// not move the morning request to 03:00 or to lunchtime. *Provisional*: the range is
    /// reasoned from "a morning slot should still be in the morning", not measured.
    static let earliestFirstSlotHour = 5
    static let latestFirstSlotHour = 11

    let dailyRequestLimit: Int

    init(dailyRequestLimit: Int = Self.dailyRequestLimit) {
        self.dailyRequestLimit = dailyRequestLimit
    }

    /// The user's own local day, the boundary the cap is counted against.
    ///
    /// The same shape and the same fallback as `NotificationBudget.day(containing:calendar:)`:
    /// a calendar that will not resolve an end yields a one-second window, which spends nothing
    /// and is visible rather than silently permissive.
    func day(containing date: Date, calendar: Calendar) -> Range<Date> {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start), end > start else {
            return start..<start.addingTimeInterval(1)
        }

        return start..<end
    }

    /// The four instants on `date`'s local day at which a request becomes permitted, ascending.
    ///
    /// `wakeTime` moves the first one. It comes from `.sleepAnalysis`, which is **already
    /// authorised and already read** — `hoursSinceWake` is a shipped feature — so nothing new
    /// is requested from HealthKit for this.
    ///
    /// The line that matters for compliance: health data decides **when** a request is made,
    /// never what is in it. The payload is a coordinate and a time, and there is no path from
    /// this argument to it.
    func slots(on date: Date, calendar: Calendar, wakeTime: Date? = nil) -> [Date] {
        let start = calendar.startOfDay(for: date)

        let firstHour = wakeTime
            .map { calendar.component(.hour, from: $0) }
            .map { min(max($0, Self.earliestFirstSlotHour), Self.latestFirstSlotHour) }
            ?? Self.fallbackFirstSlotHour

        // Deduplicated and sorted, so a wake hour clamped up to 11 cannot produce two slots an
        // hour apart and a `latestFirstSlotHour` raised past 12 in a later edit cannot silently
        // create a fifth.
        let hours = Set([firstHour] + Self.fixedSlotHours).sorted()

        return hours.compactMap {
            calendar.date(byAdding: .hour, value: $0, to: start)
        }
    }

    /// How many requests the archive already accounts for on `date`'s day.
    ///
    /// `issueTimes` may be any window; anything outside the day is ignored rather than trusted,
    /// so a caller passing a wider window gets the right answer instead of an inflated one.
    ///
    /// Not clamped to the cap: a day that somehow holds five issues should read as five. The
    /// number exists to be checked against, so it has to be able to disagree.
    func spentRequests(on date: Date, given issueTimes: [Date], calendar: Calendar) -> Int {
        let window = day(containing: date, calendar: calendar)

        return issueTimes.filter { window.contains($0) }.count
    }

    /// How many requests are left on `date`'s day. Never negative.
    func remainingRequests(on date: Date, given issueTimes: [Date], calendar: Calendar) -> Int {
        max(0, dailyRequestLimit - spentRequests(on: date, given: issueTimes, calendar: calendar))
    }

    /// The slot a request is currently owed for, or `nil` when nothing is due.
    ///
    /// Due means: a slot has passed today, the archive holds no issue at or after it, and the
    /// day's cap is not spent. The newest such slot is returned, so a phone that was asleep
    /// through the morning makes **one** request on waking rather than three catching up.
    func dueSlot(asOf now: Date,
                 given issueTimes: [Date],
                 calendar: Calendar,
                 wakeTime: Date? = nil) -> Date? {
        guard remainingRequests(on: now, given: issueTimes, calendar: calendar) > 0 else {
            return nil
        }

        let newestIssue = issueTimes.filter { $0 <= now }.max()

        return slots(on: now, calendar: calendar, wakeTime: wakeTime)
            .filter { $0 <= now }
            .filter { slot in newestIssue.map { $0 < slot } ?? true }
            .max()
    }

    /// Whether a request may be made right now.
    func admitsRequest(asOf now: Date,
                       given issueTimes: [Date],
                       calendar: Calendar,
                       wakeTime: Date? = nil) -> Bool {
        dueSlot(asOf: now, given: issueTimes, calendar: calendar, wakeTime: wakeTime) != nil
    }
}
