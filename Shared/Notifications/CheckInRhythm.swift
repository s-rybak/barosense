import Foundation

<<<<<<< HEAD
/// The time of day this user usually writes a check-in, read off their own check-ins.
///
/// A reminder is only worth sending at a moment the user was already likely to be logging. Fixed
/// at 09:00 it interrupts a night-shift worker mid-sleep; placed where their own entries cluster
/// it arrives when they are used to answering. Nothing here is a statement about the user's
/// health — it is the clock reading of their own past taps, and it never leaves the device.
///
/// ## Why a circular mean and not an average
///
/// Times of day wrap. Someone who logs at 23:40 and 00:20 has a habit centred on midnight, and
/// the arithmetic mean of 1420 and 20 minutes is 720 — 12:00, the one time of day they are
/// demonstrably *not* logging. Each timestamp is therefore mapped to a point on the unit circle
/// (`θ = 2π · minute / 1440`), the points are averaged as vectors, and the mean angle is read
/// back. The vector's length falls out of the same arithmetic and is the useful second number:
/// `concentration` is 1 when every check-in is at the same minute and 0 when they are spread
/// evenly round the clock, which is what tells a habit from a coincidence.
///
/// ## Cold start
///
/// Usable from the third check-in — `CLAUDE.md` constraint 5 applied to this feature. Below that
/// there is no reading at all rather than a confident one off two points, and the caller falls
/// back to a fixed hour (`CheckInReminderPlanner`).
struct CheckInRhythm: Hashable, Sendable {

    /// Minutes past local midnight, `0..<1440`.
    let minuteOfDay: Int

    /// Mean resultant length, 0–1. How tightly the check-ins cluster around `minuteOfDay`.
    ///
    /// Not a probability and not accuracy. It is a spread measure over the user's own past
    /// timestamps, and it is here so a caller can decline to act on a scattered one rather than
    /// place a reminder at an hour the arithmetic produced but the user never uses.
    let concentration: Double

    /// How many check-ins the reading was taken from.
    let sampleCount: Int

    /// The fewest check-ins a reading may be taken from.
    static let minimumSampleCount = 3

    /// Below this the times are too spread out to name an hour.
    ///
    /// 0.35 is roughly the resultant of check-ins scattered across an eight-hour band — a waking
    /// day's worth, which is another way of saying "no particular time". Above it the cluster is
    /// tight enough that the mean lands inside the band the user actually logs in. A judgement,
    /// calibrated on the arithmetic rather than on data this app has yet collected: revisit it
    /// once there are real distributions to look at.
    static let minimumConcentration = 0.35

    /// Whether this reading is tight enough to place a reminder on.
    var isDependable: Bool {
        sampleCount >= Self.minimumSampleCount && concentration >= Self.minimumConcentration
    }

    /// The reading's hour and minute, for building a date out of.
    var hour: Int { minuteOfDay / 60 }

    var minute: Int { minuteOfDay % 60 }
}

extension CheckInRhythm {

    /// Minutes in a day, as this type counts them. Fixed at 1440 rather than asked of the
    /// calendar: this is the circle the angles are mapped onto, and a daylight-saving day of
    /// 1380 or 1500 minutes would move every reading on it by a few minutes for one day a year.
    /// The wall-clock hour is what the reminder is placed at, and that is what the user's habit
    /// is expressed in.
    static let minutesPerDay = 1440

    /// The reading over `checkIns`, or `nil` when there are too few to take one.
    ///
    /// `calendar` decides what "time of day" means, so a test can pin a time zone instead of
    /// passing in one and failing in another.
    static func read(from checkIns: [CheckIn], calendar: Calendar) -> CheckInRhythm? {
        let minutes = checkIns.map { minuteOfDay(of: $0.timestamp, calendar: calendar) }

        return read(fromMinutesOfDay: minutes)
    }

    /// The same reading over bare minute-of-day values. Split out so the circular arithmetic is
    /// testable without building check-ins around it.
    static func read(fromMinutesOfDay minutes: [Int]) -> CheckInRhythm? {
        guard minutes.count >= minimumSampleCount else { return nil }

        let radiansPerMinute = 2 * Double.pi / Double(minutesPerDay)
        var x = 0.0
        var y = 0.0
        for minute in minutes {
            let angle = Double(minute) * radiansPerMinute
            x += cos(angle)
            y += sin(angle)
        }
        x /= Double(minutes.count)
        y /= Double(minutes.count)

        let concentration = (x * x + y * y).squareRoot()

        // Antipodal timestamps — 06:00 and 18:00, and nothing else — cancel to the origin, where
        // there is no angle to read. Reported at minute 0 with concentration 0, which
        // `isDependable` then refuses: a reading with no direction must not be given one.
        guard concentration > 0 else {
            return CheckInRhythm(minuteOfDay: 0, concentration: 0, sampleCount: minutes.count)
        }

        // `atan2` gives (-π, π]; the shift puts it back on [0, 2π) so the minute is never
        // negative. The modulo catches the one value that rounds up onto 1440.
        let angle = atan2(y, x)
        let positive = angle < 0 ? angle + 2 * Double.pi : angle
        let minuteOfDay = Int((positive / radiansPerMinute).rounded()) % minutesPerDay

        return CheckInRhythm(minuteOfDay: minuteOfDay,
                             concentration: concentration,
                             sampleCount: minutes.count)
    }

    /// Minutes past local midnight for one instant. Seconds are dropped — a reminder is placed to
    /// the minute, and carrying a resolution the output does not use invites a caller to believe
    /// in it.
    static func minuteOfDay(of date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)

        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
=======
/// The hour of the day the user tends to check in at, and how tightly they hold to it.
///
/// The whole point of the check-in reminder is that it arrives when the person is already in
/// the habit of answering. A fixed 9 a.m. nudge is an interruption; the hour they already
/// reach for the app is a prompt.
struct CheckInRhythm: Hashable, Sendable {

    /// Seconds after local midnight, `0..<86_400`.
    let secondsFromMidnight: Int

    /// How tightly the check-ins cluster around that time, 0 to 1.
    ///
    /// The resultant length of the circular mean: 1 is every check-in at the same minute, 0 is
    /// spread evenly around the clock. Reported rather than hidden because it is the only
    /// thing that separates "this person logs at 21:30" from "this person's times average out
    /// to 21:30 and mean nothing".
    let consistency: Double

    /// How many check-ins the estimate was drawn from.
    let sampleCount: Int

    /// Whether this rhythm is worth timing a reminder to, as opposed to falling back to the
    /// default hour.
    var isReliable: Bool {
        sampleCount >= CheckInRhythmAnalysis.minimumSampleCount
            && consistency >= CheckInRhythmAnalysis.minimumConsistency
    }
}

/// Deriving the check-in rhythm from history, and turning it into the next instant to ask at.
///
/// Pure arithmetic over `CheckIn` values with the `Calendar` handed in. No store, no clock of
/// its own, no view — the same rule the feature pipeline follows, and for the same reason:
/// "when does this person usually log" has to be answerable in a unit test from synthetic
/// timestamps.
///
/// ## Why a circular mean rather than an average
///
/// Time of day is an angle, not a number. Someone who logs at 23:40 and 00:20 averages, on a
/// straight arithmetic mean, to **12:00** — the middle of the day they never use, and the
/// worst possible time to interrupt them. Mapping each timestamp onto the unit circle,
/// averaging the vectors and reading the angle back gives 00:00, which is what the two
/// timestamps actually say. The length of that mean vector falls out of the same sum for
/// free, and is what `consistency` reports.
enum CheckInRhythmAnalysis {

    /// The hour used until the history says otherwise: 20:00 local.
    ///
    /// Cold start is a requirement, not an edge case (`CLAUDE.md`, constraint 5) — the app has
    /// to be useful on day one, and a reminder feature that waits a month for enough data is
    /// a feature that is off when the user is deciding whether to keep the app. Early evening
    /// is the compromise: after the working day for most people, before the hours where a
    /// notification is an intrusion rather than a prompt.
    static let defaultSecondsFromMidnight = 20 * 3600

    /// Below this many check-ins the estimate is noise wearing a number's clothes.
    static let minimumSampleCount = 3

    /// Below this resultant length the times are spread widely enough that their mean points
    /// at an hour the user may never have used. 0.3 is a deliberately low bar: the cost of
    /// being wrong is a reminder at an unhelpful hour, and the cost of being too strict is
    /// falling back to a default hour that is *certainly* not theirs.
    static let minimumConsistency = 0.3

    /// How far back the rhythm is read from. Long enough to hold a habit, short enough that a
    /// routine changed a season ago does not outvote the current one.
    static let lookbackDays = 30

    private static let secondsPerDay = 24 * 3600

    /// The rhythm in `checkIns`, or `nil` when there is nothing to read one from.
    ///
    /// `nil` rather than a rhythm carrying the default hour, so the caller has to decide what
    /// to do about an absent one. The two are not the same fact and the Settings caption says
    /// different things about them.
    static func rhythm(from checkIns: [CheckIn], calendar: Calendar = .current) -> CheckInRhythm? {
        guard !checkIns.isEmpty else { return nil }

        var sumSin = 0.0
        var sumCos = 0.0

        for checkIn in checkIns {
            let angle = 2 * Double.pi * Double(seconds(from: checkIn.timestamp, calendar: calendar))
                / Double(secondsPerDay)
            sumSin += sin(angle)
            sumCos += cos(angle)
        }

        let count = Double(checkIns.count)
        let resultant = (sumSin * sumSin + sumCos * sumCos).squareRoot() / count

        // Vectors that cancel out exactly — two check-ins twelve hours apart, say. The mean
        // angle is genuinely undefined there rather than merely uncertain, and
        // `atan2(0, 0)` would answer 0 (midnight) with a straight face.
        guard resultant > 0 else { return nil }

        // `atan2` returns −π…π; the negative half is the second half of the clock.
        var mean = atan2(sumSin, sumCos)
        if mean < 0 { mean += 2 * Double.pi }

        let seconds = Int((mean / (2 * Double.pi) * Double(secondsPerDay)).rounded())

        return CheckInRhythm(secondsFromMidnight: seconds % secondsPerDay,
                             consistency: resultant,
                             sampleCount: checkIns.count)
    }

    /// The time of day a reminder should be timed to: the user's own hour when the history
    /// supports one, the default otherwise.
    static func reminderSecondsFromMidnight(for rhythm: CheckInRhythm?) -> Int {
        guard let rhythm, rhythm.isReliable else { return defaultSecondsFromMidnight }
        return rhythm.secondsFromMidnight
    }

    /// The first instant strictly after `date` at `secondsFromMidnight` local time.
    ///
    /// Strictly after, so a planner running at exactly the reminder minute schedules
    /// tomorrow's rather than one that is already due and would fire the moment it is handed
    /// over.
    ///
    /// Built by adding an offset to the start of the day rather than by asking for date
    /// components, because the two differ on the days that matter: on a spring-forward day
    /// there is no 02:30 at all, and `DateComponents` matching for one returns either nothing
    /// or the wrong hour. Adding seconds to midnight always lands somewhere real.
    static func nextOccurrence(ofSecondsFromMidnight secondsFromMidnight: Int,
                               after date: Date,
                               calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: date)
        let candidate = today.addingTimeInterval(TimeInterval(secondsFromMidnight))

        guard candidate <= date else { return candidate }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
            ?? today.addingTimeInterval(TimeInterval(secondsPerDay))
        return tomorrow.addingTimeInterval(TimeInterval(secondsFromMidnight))
    }

    /// Seconds from local midnight to `date`.
    ///
    /// Measured from `startOfDay` rather than read off the hour and minute components, so a
    /// day that is 23 or 25 hours long is described by how far into it the check-in fell.
    private static func seconds(from date: Date, calendar: Calendar) -> Int {
        Int(date.timeIntervalSince(calendar.startOfDay(for: date)))
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)
    }
}
