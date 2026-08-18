import Foundation

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
    }
}
