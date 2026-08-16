import Foundation

/// Drives the check-in reminder: reads the user's own logging times, plans the next few slots,
/// and hands the plan to `NotificationDispatcher`.
///
/// ## Why this runs on scene activation and nowhere else
///
/// There is no timer here, no background task, no observer — `CLAUDE.md` constraint 4. The
/// system holds the scheduled notifications and fires them without waking Barosense, so the only
/// thing the app has to do is keep the next week's worth in step with what it knows. Doing that
/// when the user brings the app forward costs one store read and, on a day when nothing has
/// changed, zero cross-process calls. `CheckInReminderPlanner.horizonDays` is what makes that
/// enough: a plan a week deep survives a week of the app not being opened, which is precisely
/// the stretch a reminder is for.
///
/// ## Permission
///
/// **A reconcile pass never asks for it.** iOS grants exactly one chance to show the permission
/// prompt: a refusal is permanent as far as the app is concerned, repairable only by a trip to
/// Settings that nobody makes. A prompt raised as a side effect of a scene activation spends that
/// one chance on a dialog the user has no context for, and "Don't Allow" is the reflex.
///
/// So the ask has an owner, and it is never this pass. `CheckInReminderPrimer` explains what the
/// app would send and in whose words, and only a tap on its own button reaches iOS; after that,
/// the switch in Settings. Both routes go through `acceptPrimer` / `SettingsModel.toggleReminder`
/// rather than through a reconcile.
///
/// The cost of getting this wrong is asymmetric, which is why it is worth a screen: an
/// unexplained prompt loses the feature for that install for good, and an explained one that is
/// declined loses nothing that the Settings switch cannot give back.
@MainActor
final class CheckInReminderController {

    private let checkIns: any CheckInStore
    private let store: any NotificationStore
    private let deliverer: any NotificationDelivering
    private let preferences: any ReminderPreferenceStore

    /// How far back the rhythm is read.
    ///
    /// 30 days. Long enough that a habit is visible and that a fortnight's holiday does not erase
    /// it, short enough that a habit the user has since changed stops dragging the reading back
    /// to where it used to be. Every check-in in the window counts the same — weighting the
    /// recent ones more is the obvious refinement and needs real distributions to calibrate
    /// against, which this app has not collected yet.
    static let rhythmLookbackDays = 30

    /// The pass currently running, if any. Every new one waits for it.
    ///
    /// Two callers can ask at once — a scene activation and a check-in being saved land within
    /// milliseconds of each other — and `refresh` suspends several times. Without this they
    /// interleave: both read a log with no rows in it, both decide nothing is scheduled yet, and
    /// both schedule the whole week. Observed on device, as fourteen rows for seven slots.
    ///
    /// Chained rather than coalesced. A second pass usually has nothing to do and ends quiet, but
    /// the one that follows a check-in is exactly the pass that has to run — it is what withdraws
    /// that evening's reminder — so dropping it would be dropping the only one that mattered.
    private var inFlight: Task<Void, Never>?

    init(checkIns: any CheckInStore,
         store: any NotificationStore,
         deliverer: any NotificationDelivering = UserNotificationCenterDeliverer(),
         preferences: any ReminderPreferenceStore = UserDefaultsReminderPreferenceStore()) {
        self.checkIns = checkIns
        self.store = store
        self.deliverer = deliverer
        self.preferences = preferences
    }

    /// Whether the reminder should be planned at all: the shipped kill switch and the user's own
    /// choice, which are separate powers and both have to say yes.
    private var isEnabled: Bool {
        CheckInReminderPlanner.isEnabled && preferences.isCheckInReminderEnabled()
    }

    /// One reconciliation pass.
    ///
    /// `language` and `calendar` are passed in rather than read from `Locale.current`, for the
    /// reason every date on screen is: the app's language is not the device's while a pinned
    /// selection is in effect, and a reminder that fires on Thursday must be in the language the
    /// user is actually reading the app in. See `LanguageController`.
    ///
    /// Swallows its failures. Nothing here is actionable by the user — a store that will not read
    /// has already put a bigger message on screen — and a reminder that did not get scheduled is
    /// a missing nudge, not lost data.
    /// A pass runs even when the reminder is switched off, and that is the point: an empty plan
    /// is a plan that wants none of what is outstanding, so the dispatcher withdraws the week
    /// already handed to the system and marks the rows cancelled. Returning early here instead
    /// would leave the user switching reminders off and going on getting them until the last one
    /// scheduled before the switch had fired.
    func refresh(language: AppLanguage, calendar: Calendar, now: Date = .now) async {
        let previous = inFlight
        let task = Task { [weak self] in
            await previous?.value
            await self?.reconcile(language: language, calendar: calendar, now: now)
        }
        inFlight = task

        await task.value
    }

    private func reconcile(language: AppLanguage, calendar: Calendar, now: Date) async {
        let dispatcher = NotificationDispatcher(store: store,
                                                deliverer: deliverer,
                                                calendar: calendar)

        do {
            let plan = try await plan(now: now, calendar: calendar)
            try await dispatcher.reconcile(plan: plan, now: now, language: language)
        } catch {
            BarosenseLog.notifications.error("reminder refresh failed")
        }
    }

    // MARK: - The permission ask

    /// Whether the reminder should be explained before anything asks iOS for it.
    ///
    /// Once per install, whichever way it is answered, and only while there is still something to
    /// ask for: an install that already has permission — a reinstall over a previous grant, or a
    /// restore — is not shown an explanation of a thing that is already working.
    ///
    /// Deliberately does not distinguish "never asked" from "asked and refused". iOS does not
    /// offer that distinction through any API this app has, and the safe reading of both is the
    /// same: do not raise a system prompt on your own initiative.
    func shouldOfferPrimer() async -> Bool {
        guard CheckInReminderPlanner.isEnabled,
              !preferences.hasOfferedCheckInReminder(),
              await !deliverer.isAuthorized()
        else {
            return false
        }

        return true
    }

    /// The user asked for the reminder from the primer.
    ///
    /// The one path on which a permission prompt is raised without a switch being tapped, and it
    /// is not really an exception: a tap on "turn these on" *is* the context the prompt would
    /// otherwise be missing. The pass that follows is what schedules the first week — a grant
    /// that nothing re-planned against would leave the user waiting until the next launch.
    func acceptPrimer(language: AppLanguage, calendar: Calendar, now: Date = .now) async {
        preferences.setHasOfferedCheckInReminder(true)
        preferences.setCheckInReminderEnabled(true)
        _ = await deliverer.requestAuthorization()

        await refresh(language: language, calendar: calendar, now: now)
    }

    /// "Not now".
    ///
    /// Writes the preference *off*, rather than leaving it on and simply not asking. The two
    /// differ in what Settings then says: a preference left on with no permission behind it is
    /// `ReminderSettings.isBlockedBySystem`, whose caption sends the user to iOS Settings to
    /// re-enable something they were never asked about. Off is the truthful reading — the user
    /// declined — and tapping the switch there raises the prompt for the first time, which is
    /// exactly the second chance this is meant to preserve.
    ///
    /// No reconcile follows: nothing can be scheduled without permission, so there is nothing
    /// outstanding for a pass to withdraw.
    func declinePrimer() {
        preferences.setHasOfferedCheckInReminder(true)
        preferences.setCheckInReminderEnabled(false)
    }

    // MARK: - Planning

    /// The slots to ask for, as notifications. Empty when the reminder is switched off, which is
    /// what makes the pass stand down rather than skip — see `refresh`.
    private func plan(now: Date, calendar: Calendar) async throws -> [PlannedNotification] {
        guard isEnabled else { return [] }

        let lookback = TimeInterval(Self.rhythmLookbackDays) * 24 * 3600
        let recent = try await checkIns.checkIns(in: (now - lookback)..<now)

        let planner = CheckInReminderPlanner(
            rhythm: CheckInRhythm.read(from: recent, calendar: calendar),
            calendar: calendar
        )

        return planner
            .slots(from: now, lastCheckIn: recent.last?.timestamp)
            .map { PlannedNotification(kind: .checkInReminder, fireAt: $0) }
    }
}
