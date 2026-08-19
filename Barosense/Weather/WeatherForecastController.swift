import Foundation
import Observation

/// Owns forecast refreshes on the phone: when to ask, and what the screen is told afterwards.
///
/// Deliberately thin. Every decision — the two switches, the permission, the slot budget, the
/// bootstrap — is `WeatherForecastRefresher`'s, in `Shared/`, where a test reaches it without
/// a network. This type supplies the two things only the app layer knows: the clock and the
/// user's wake time.
///
/// ## Battery and quota
///
/// **No new wake source.** It runs on the same two executions the barometer already has: a
/// foreground activation, and the existing `BGAppRefreshTask`. There is no timer here, no
/// observer, and no second background identifier — `CLAUDE.md` constraint 4 is met by there
/// being nothing new to budget.
///
/// An activation with nothing due costs one indexed store read and no network at all.
@MainActor
@Observable
final class WeatherForecastController {

    /// What the last pass did. Read by the chart to decide whether it is drawing a WeatherKit
    /// curve or the local model's, and by nothing that makes a claim to the user.
    private(set) var lastOutcome: WeatherForecastRefresher.Outcome?

    /// Bumped when rows land, so the chart can reload without polling — the same mechanism
    /// `PressureCollectionController.lastUpdateAt` gives the barometer.
    private(set) var lastUpdateAt: Date?

    private let refresher: WeatherForecastRefresher

    /// The training log, read for the end of the most recent sleep session.
    ///
    /// Read from the **log**, not from HealthKit: the rows are already there, this needs no new
    /// type and no new authorisation, and a settings-free read of a local table costs nothing.
    /// `hoursSinceWake` is a shipped feature (`HealthFeatureExtractor`).
    private let healthLog: any HealthSampleStore

    private let calendar: Calendar

    /// One pass in flight at a time. Two activations can land milliseconds apart — a scene
    /// activation and a background task completing — and both would otherwise see an empty
    /// day and each spend the same slot.
    private var inFlight: Task<Void, Never>?

    init(refresher: WeatherForecastRefresher,
         healthLog: any HealthSampleStore,
         calendar: Calendar = .current) {
        self.refresher = refresher
        self.healthLog = healthLog
        self.calendar = calendar
    }

    /// Call from the scene-phase observer when the scene becomes `.active`.
    ///
    /// Cheap to call often: the budget decides whether anything goes out, so a user flipping
    /// in and out of the app does not turn into requests.
    func sceneDidBecomeActive() {
        let previous = inFlight
        inFlight = Task { [weak self] in
            await previous?.value
            await self?.refresh()
        }
    }

    /// Call from the barometer's background task. Awaited rather than detached, because the
    /// system suspends the app the moment that closure returns.
    func handleBackgroundRefresh() async {
        await refresh()
    }

    /// Runs one pass and records what it did.
    func refresh(asOf now: Date = .now) async {
        let outcome = await refresher.refresh(asOf: now, wakeTime: await wakeTime(asOf: now))
        lastOutcome = outcome

        if case .refreshed = outcome {
            lastUpdateAt = now
        }
    }

    /// When the user most recently woke, or `nil` when the log cannot say.
    ///
    /// **This decides the moment of a request, never its content.** The payload
    /// `WeatherKitForecastProvider` sends is a coordinate and a time, and there is no path from
    /// this value to it — `.claude/context/pressure-forecast-spec.md` §4.2.
    ///
    /// A failure or an absent session yields `nil`, and `WeatherRequestBudget` falls back to
    /// 08:00 local.
    private func wakeTime(asOf now: Date) async -> Date? {
        let features = try? await HealthFeatureExtractor.extract(from: healthLog,
                                                                 at: now,
                                                                 calendar: calendar)
        guard let hoursSinceWake = features?.hoursSinceWake else { return nil }

        return now.addingTimeInterval(-hoursSinceWake * 3600)
    }
}
