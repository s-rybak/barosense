import BackgroundTasks
import Foundation
import Observation

/// Owns barometer collection on the phone: when to sample, and what the watch is told.
///
/// The phone is the only device that samples. Its readings go into the durable local log,
/// which is the training history; the watch is a second screen onto the newest of them and
/// measures nothing itself. **One sensor, one series** — two devices at two altitudes
/// writing into one log is the altitude contamination of `.claude/context/ml-spec.md` §3
/// manufactured on purpose, because a phone on a desk and a watch three floors up disagree
/// by several hPa and nothing in the row says which device it came from.
///
/// Which of the two sensors should be the one is a real trade, and the phone wins on
/// coverage. Both devices give the app only opportunistic background execution, but the
/// phone is picked up dozens of times a day, is charged nightly rather than budgeted
/// hourly, and needs no radio hop before the reading reaches the log it is going to be
/// trained on. What it loses is the wrist: a phone left on a desk while the user walks
/// outside records the desk.
///
/// ## Sampling cost
///
/// 1. **What runs the sensor, how often?** Foreground activation, floored at one reading per
///    15 min by `PressureSamplingPolicy`; plus a `BGAppRefreshTask` requested 15 min out.
///    Upper bound: 96 readings a day, and only if iOS grants every wake, which it will not.
/// 2. **Work per reading?** One `CMAltimeter` start / first-sample / stop — the sensor
///    reports at roughly 1 Hz, so ≈1 s, hard-capped at 5 s by `CoreMotionPressureSource` —
///    one SwiftData upsert, and at most one `updateApplicationContext` write. An activation
///    the rate limit declines costs nothing at all: no sensor, no store write, no publish.
/// 3. **What stays powered?** The barometer, for that ≈1 s and no longer;
///    `stopRelativeAltitudeUpdates` runs on every exit path. No location, no network, no
///    display wake.
/// 4. **If the wake never fires?** Often it will not — iOS grants `BGAppRefreshTask` from
///    usage history and throttles it hard under Low Power Mode. Foreground activation is the
///    backstop and in practice the main source: a phone used through the day covers most
///    15-minute slots of waking hours. Overnight is a gap, and the coverage features exist
///    to tell the model so rather than to hide it.
/// 5. **Unverified.** That `CMAltimeter` delivers a reading inside a `BGAppRefreshTask` is
///    expected — the app is executing for the length of the task — but it has not been
///    confirmed on device here. If it does not, the log simply grows only from foreground
///    use, and `BarosenseLog.pressure` is where that shows up.
///
/// Kill-switch: `PressureSamplingPolicy.isBackgroundRefreshEnabled`.
@MainActor
@Observable
final class PressureCollectionController {

    /// Most recent reading this device took. Drives the watch's number and the card's
    /// figure; the history lives in the log.
    private(set) var latest: PressureSample?

    /// Bumped after every reading that lands. The chart watches this rather than polling —
    /// a reading taken while the user is looking at the screen should appear, and the
    /// alternative is a timer that runs whether or not anything changed.
    private(set) var lastUpdateAt: Date?

    /// True once a sampling attempt has finished, whatever the outcome. Lets the view
    /// distinguish "still reading the sensor" from "nothing has ever been recorded".
    private(set) var hasAttemptedSample = false

    /// Whether this device has a barometer at all. `false` on every simulator and on iPad,
    /// where the chart will never fill and has to say so instead of promising data.
    let isBarometerAvailable: Bool

    private let recorder: PressureSampleRecorder
    private let display: any PressureDisplayLink

    /// Stamps each reading with the place it was taken in. `nil` on a build with no location
    /// wiring at all — the watch does not sample and previews do not record — and a `nil`
    /// here simply leaves `PressureSample.locationEpochID` unset, which every consumer already
    /// reads as ordinary.
    private let locationEpochs: LocationEpochRecorder?

    private var didStart = false
    private var sampleTask: Task<Void, Never>?

    /// What the watch was last told. In memory, and only ever compared against — a publish
    /// the app skips because nothing changed is not a publish worth remembering across
    /// launches.
    private var lastPublished: PressureDisplaySnapshot?

    init(recorder: PressureSampleRecorder,
         display: any PressureDisplayLink,
         locationEpochs: LocationEpochRecorder? = nil) {
        self.recorder = recorder
        self.display = display
        self.locationEpochs = locationEpochs
        self.isBarometerAvailable = recorder.isAvailable
    }

    /// Takes the launch reading. Call once from the composition root. Idempotent.
    ///
    /// Deliberately does **not** arm the background chain — see `armBackgroundRefresh` —
    /// and deliberately does **not** raise the Motion & Fitness prompt. This runs from
    /// `App.init`, which is before onboarding has drawn a single frame: starting the sensor
    /// there puts a system permission sheet in front of someone who has not yet been told
    /// what the app measures or why. Onboarding's Apple Health step is what asks — see
    /// `requestAccess()` — and every launch after that answer finds the status settled and
    /// samples as before.
    func start() {
        guard !didStart else { return }
        didStart = true

        guard recorder.isAccessRequested else { return }

        sample()
    }

    /// Raises the Motion & Fitness prompt, and records what the sensor answers with.
    ///
    /// `CMAltimeter` has no authorisation call of its own, so the request *is* a reading:
    /// starting the sensor is what puts the sheet on screen. Awaiting it means the step
    /// that asked also lands the first row in the log rather than leaving the barometer
    /// idle until the next activation.
    ///
    /// Reports nothing back. A refusal is a gap in the history, not a state the caller can
    /// repair, and it is indistinguishable here from a device without a barometer — both
    /// are handled by the coverage features rather than by a screen.
    func requestAccess() async {
        // `requestingLocationFix: true` like every other foreground path. It cannot stack a
        // second system sheet on the Motion & Fitness one: the epoch recorder *reads*
        // location authorisation and returns the stored epoch when it is not granted, so
        // onboarding asks for the radio only once the user has been offered it on its own
        // step.
        await sampleAndPublish(requestingLocationFix: true)
    }

    /// Arms the background-refresh chain. Call from the root view, not from `App.init`.
    ///
    /// The split is not stylistic. `BGTaskScheduler.submit` raises an **Objective-C
    /// exception** — not a Swift error, so no `catch` reaches it — when the identifier has
    /// no registered handler yet, and `.backgroundTask(.appRefresh:)` performs that
    /// registration while the scene is being built, which is after `App.init` has returned.
    /// Scheduling from the composition root therefore terminates the process on every
    /// launch. It is caught by the first test run, because the test host launches the app.
    ///
    /// Idempotent: `scheduleNextRefresh` cancels before it submits.
    func armBackgroundRefresh() {
        scheduleNextRefresh()
    }

    /// Call from the scene-phase observer when the scene becomes `.active`.
    ///
    /// Cheap to call often: the recorder's rate limit decides whether the sensor actually
    /// runs, so a user flipping in and out of the app does not turn into sensor time.
    ///
    /// Unguarded, unlike `start()`. Its only caller is the root view, which exists only
    /// once onboarding is behind the user — so a prompt raised from here is one the user
    /// skipped rather than one they were never offered, and it lands with the app on
    /// screen.
    func sceneDidBecomeActive() {
        sample()
    }

    /// Handles a `BGAppRefreshTask`.
    ///
    /// Awaits the reading rather than firing and forgetting: the system is holding the app
    /// awake for the duration of this call and suspends it as soon as the task completes, so
    /// a detached task would be killed mid-write. Reschedules before returning — a chain
    /// that forgets to re-arm itself stops after one wake.
    func handleBackgroundRefresh() async {
        // `requestingLocationFix: false` is not caution, it is the documented rule: a
        // when-in-use app's attempt to start location updates in the background fails, and
        // `BGAppRefreshTask` is not one of the states iOS counts as "in use". The reading is
        // stamped with whatever the last foreground session resolved.
        await sampleAndPublish(requestingLocationFix: false)
        scheduleNextRefresh()
    }

    /// Rows the chart draws: the trailing window, ascending.
    func samples(trailing windowSeconds: TimeInterval) async -> [PressureSample] {
        (try? await recorder.samples(trailing: windowSeconds)) ?? []
    }

    // MARK: - Sampling

    private func sample() {
        // One attempt in flight at a time. Two overlapping calls would serialise inside the
        // recorder anyway; cancelling is how the older one stops holding the sensor open.
        sampleTask?.cancel()
        sampleTask = Task { await sampleAndPublish(requestingLocationFix: true) }
    }

    /// Reads the barometer, writes what it read, and offers it to the watch.
    ///
    /// Failures are swallowed on screen. Every reason the sensor can fail — no barometer,
    /// Motion & Fitness denied, no answer inside the timeout — produces the same outcome
    /// from here: no new row, and a gap the coverage features already account for. There is
    /// nothing the card could usefully say about any of them beyond what its empty state
    /// already says. They do reach the log, because from the chart's side every way this
    /// pipeline can fail looks identical.
    private func sampleAndPublish(asOf now: Date = .now,
                                  requestingLocationFix: Bool) async {
        defer { hasAttemptedSample = true }

        // Asked before the epoch is resolved, because resolving it in the foreground powers the
        // radio. The floor lives inside `record(asOf:)`, so an activation it is about to refuse
        // would otherwise still have paid for a fix — twenty activations in an hour, twenty
        // fixes, one row. Nothing is skipped that a written row would have used: a declined
        // reading has nowhere to put an epoch id.
        let epochID = await recorder.admitsReading(asOf: now)
            ? await locationEpochID(asOf: now, requestingFix: requestingLocationFix)
            : nil

        let recorded: PressureSample?
        do {
            recorded = try await recorder.record(asOf: now, locationEpochID: epochID)
        } catch {
            BarosenseLog.pressure.error(
                "barometer read failed: \(String(describing: error), privacy: .public)"
            )
            return
        }

        // `nil` is the fifteen-minute rate limit declining, not a failure. Nothing has
        // changed, so there is nothing to redraw and nothing to tell the watch.
        guard let recorded else { return }

        latest = recorded
        lastUpdateAt = now

        await publish(recorded, asOf: now)
    }

    /// Which epoch this reading belongs to.
    ///
    /// On a foreground activation that the sampling floor admits, this may take one fix — the
    /// only place in the app that ever does — and, on a move past 25 km, spend one geocode. On
    /// a background wake it reads the stored row and powers nothing. Either way a failure
    /// yields `nil` and the reading is still taken: the barometer is the feature, and the place
    /// is context for it.
    private func locationEpochID(asOf now: Date, requestingFix: Bool) async -> UUID? {
        guard let locationEpochs else { return nil }

        if requestingFix {
            return await locationEpochs.currentEpoch(asOf: now)?.id
        }
        return await locationEpochs.storedEpoch()?.id
    }

    /// Offers the reading, its tendency and the short window behind it to the watch.
    ///
    /// All three are computed here and shipped rather than derived on the other side, because
    /// the watch holds no history to derive them from — it is a display, not a second log.
    ///
    /// One store read serves all three. The window fetched is the wider of the two the
    /// consumers ask for, so the arrow, the printed delta and the plotted line are cut from
    /// exactly the same array: a line drawn from one read and an arrow from another could
    /// disagree across a sample landing between them, and that disagreement would be
    /// invisible until someone screenshotted it.
    private func publish(_ sample: PressureSample, asOf now: Date) async {
        let window = max(PressureTrend.windowSeconds, PressureWatchSeries.windowSeconds)
        let history = (try? await recorder.samples(trailing: window, asOf: now)) ?? []

        let snapshot = PressureDisplaySnapshot(
            sample: sample,
            trend: PressureTrend.make(from: history, asOf: now),
            recent: PressureWatchSeries.make(from: history, asOf: now),
            deltaHPaPer3h: PressureTrend.delta(from: history, asOf: now)
        )
        guard PressureDisplayPolicy.shouldPublish(snapshot, lastPublished: lastPublished) else {
            return
        }

        await display.publish(snapshot)
        lastPublished = snapshot
    }

    // MARK: - Background refresh

    /// Asks for the next wake, roughly fifteen minutes out.
    ///
    /// `earliestBeginDate` is a floor, not a cadence — iOS decides the real interval from
    /// usage history, charge state and Low Power Mode, and grants far fewer wakes than this
    /// asks for. Asking for the minimum simply means the app is eligible as soon as it can
    /// be.
    ///
    /// The cancel is not defensive noise: it makes re-arming from both `start()` and every
    /// wake unambiguous, without depending on whether submitting a second request for the
    /// same identifier replaces the pending one or rejects it.
    private func scheduleNextRefresh() {
        guard PressureSamplingPolicy.isBackgroundRefreshEnabled else { return }

        let identifier = PressureSamplingPolicy.backgroundRefreshIdentifier
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)

        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date.now
            .addingTimeInterval(PressureSamplingPolicy.backgroundRefreshIntervalSeconds)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Ordinary in the simulator and whenever the user has turned Background App
            // Refresh off, so this is not an error. The chain stays broken until the next
            // foreground activation, which re-arms it.
            BarosenseLog.pressure.info(
                "background refresh not scheduled: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
