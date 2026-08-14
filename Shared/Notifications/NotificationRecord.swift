import Foundation

/// What a notification is for.
///
/// This enum is the registry: every notification Barosense is capable of sending has a case
/// here, and nothing may be handed to the system without one. That is what makes the log
/// answerable — "how many did we send yesterday, and what were they" is a query over stored
/// rows rather than a guess, and the daily cap in `NotificationBudget` counts against it.
///
/// Raw values are persisted. Renaming a case orphans every stored row that carries it, which
/// would silently reset that kind's history and with it the cap it was counted under.
///
/// One case today, and deliberately only one. The forecast warning `CLAUDE.md` describes has no
/// model behind it yet, and a case with nothing producing it is a row type that can never appear
/// — see the surgical-permissions rule applied to anything else the app claims to do.
enum NotificationKind: String, Codable, Sendable, CaseIterable {

    /// "How are you feeling?" — placed at the time of day this user usually writes a check-in.
    /// See `CheckInRhythm`.
    case checkInReminder
}

/// Where one notification got to.
///
/// Every state except `.scheduled` is terminal. A row is written the moment the app decides
/// something should reach the user and is never deleted on the way through, so the log holds the
/// suppressed and the cancelled as well as the sent — a cap that only recorded what it let
/// through could not be audited.
///
/// Raw values are persisted; same rule as `NotificationKind`.
enum NotificationDeliveryState: String, Codable, Sendable, CaseIterable {

    /// Handed to the system, waiting to fire.
    case scheduled

    /// The system says it fired. Confirmed against `UNUserNotificationCenter`'s own delivered
    /// list rather than inferred from the clock — a scheduled row whose time has passed is not
    /// evidence that anything reached the user.
    case delivered

    /// Dropped before it was ever handed over, because the day's allowance was already spent.
    /// See `NotificationBudget`.
    case suppressed

    /// Withdrawn after being scheduled and before it fired — the user wrote a check-in, so the
    /// reminder for that day is no longer wanted.
    case cancelled

    /// Whether this row spends one of the day's sends.
    ///
    /// `.scheduled` counts, and counts from the moment it is written rather than when it fires:
    /// the cap is a promise about what the user's day will hold, and a promise that only took
    /// effect once a notification had already arrived would let a whole day be scheduled at once.
    ///
    /// `.suppressed` and `.cancelled` do not. Nothing reached the user, and counting them would
    /// let a suppressed notification suppress the next one.
    var spendsAllowance: Bool {
        switch self {
        case .scheduled, .delivered: true
        case .suppressed, .cancelled: false
        }
    }
}

/// One row of the notification log: something Barosense decided the user should see, and what
/// became of it.
///
/// **The copy is not stored, but the language it was written in is.** The words are resolved
/// from the kind at the moment the notification is handed to the system (`NotificationCopy`);
/// storing the text itself would make every future rewording a migration. What the row has to
/// remember is which language went to the system, because the request sitting in the
/// notification centre is already rendered and iOS will not re-resolve it: without this, a user
/// who switches to Ukrainian on Tuesday goes on getting English reminders until the last one
/// scheduled before the switch has fired. `NotificationDispatcher` treats a row in the wrong
/// language as one the plan no longer wants, which withdraws and reissues it.
///
/// Nothing health-derived is here either — no intensity, no tag, no note. The log says *that*
/// the app spoke and when, never what the user had recorded. That keeps it outside the class of
/// data `CLAUDE.md` constraint 2 governs, and it is the reason a notification body may not
/// interpolate a check-in.
struct NotificationRecord: Identifiable, Hashable, Sendable {

    /// Also the identifier the notification is registered under with the system, so a row can be
    /// cancelled without a second lookup table mapping one to the other.
    let id: UUID

    let kind: NotificationKind

    /// The app's language at the moment the words were handed over — not the device's. See
    /// `LanguageController`.
    let language: AppLanguage

    /// When it is meant to reach the user. Stays put when the state changes — this is the slot
    /// the row occupies in the day's budget, and moving it would move which day it was counted
    /// against.
    let scheduledFor: Date

    private(set) var state: NotificationDeliveryState

    /// When `state` last moved. Separate from `scheduledFor` because the two answer different
    /// questions: one is when the user was meant to hear from the app, the other is when the app
    /// last learned something about that.
    private(set) var stateChangedAt: Date

    let createdAt: Date

    init(id: UUID = UUID(),
         kind: NotificationKind,
         language: AppLanguage,
         scheduledFor: Date,
         state: NotificationDeliveryState,
         createdAt: Date,
         stateChangedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.language = language
        self.scheduledFor = scheduledFor
        self.state = state
        self.createdAt = createdAt
        self.stateChangedAt = stateChangedAt ?? createdAt
    }

    /// A copy in a new state. Returns `nil` when the row is already terminal, which is how a
    /// second reconcile pass over the same delivered notification becomes a no-op instead of
    /// rewriting `stateChangedAt` on every scene activation for the life of the install.
    func moved(to state: NotificationDeliveryState, at date: Date) -> NotificationRecord? {
        guard self.state == .scheduled, state != .scheduled else { return nil }

        return NotificationRecord(id: id,
                                  kind: kind,
                                  language: language,
                                  scheduledFor: scheduledFor,
                                  state: state,
                                  createdAt: createdAt,
                                  stateChangedAt: date)
    }
}
