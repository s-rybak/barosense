import Foundation
import os

/// The app's loggers, in one place.
///
/// Added because the barometer pipeline is a chain of six links — sensor, local log,
/// uplink, WatchConnectivity, phone log, chart — and every one of them swallows its
/// failure by design. That is the right behaviour on screen (none of it is actionable by
/// the user) and the wrong behaviour for the developer: a chart that stays empty gives no
/// clue which link broke. These loggers exist so the answer is one `log stream` away
/// rather than a guess.
///
/// ## What may be logged
///
/// **Structure only.** How many rows a transfer carried, that a store failed to open, that
/// the sensor did not answer. **Never a measured value** — no pressure reading, no heart
/// rate, no SpO₂, no sleep interval, no check-in, and no timestamp of any of them. The
/// unified log is collected by `sysdiagnose` and copied off the device by whoever the user
/// sends one to, which is exactly the egress `CLAUDE.md` constraint 2 forbids. A row count
/// is not health data; a row is.
///
/// ## Why every interpolation says `privacy:`
///
/// A non-literal interpolation defaults to `.private` and renders as `<private>`, which
/// makes the log useless for the debugging it exists for. Marking each one `.public` is
/// therefore required — and having to type it is what forces the "is this a value or a
/// count?" question at the call site.
enum BarosenseLog {

    private static let subsystem = "com.barosense.app"

    /// Opening durable stores. The failure that silently costs the user their history.
    static let persistence = Logger(subsystem: subsystem, category: "persistence")

    /// Barometer sampling on the watch and the hand-off to the phone.
    static let pressure = Logger(subsystem: subsystem, category: "pressure")

    /// What the app decided to send the user, and what the system did with it.
    ///
    /// Counts and states only. A notification's *time* is a health-adjacent value here — it is
    /// derived from when this user writes check-ins — so the hour a reminder was placed at does
    /// not go in the log, only how many were placed.
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
}
