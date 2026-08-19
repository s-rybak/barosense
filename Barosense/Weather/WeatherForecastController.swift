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

    /// The §2.2 family as of the last request.
    ///
    /// Computed **at the moment of the request**, which is where
    /// `.claude/context/pressure-forecast-spec.md` §4.5 puts it: four numbers a request, read
    /// off the curve the app had just been handed, under the same `issuedAt <= t` guard as
    /// everything else. No wellbeing model consumes them yet — there is none to train — so this
    /// is where they are observable until there is.
    private(set) var lastFeatures: ForecastPressureFeatures?

    /// What the archived forecasts of the last 30 days actually achieved against the barometer.
    ///
    /// The §7 baseline comparison, running on the device rather than in a report nobody runs.
    /// The ground truth arrives by itself a few hours after each forecast, so this is the one
    /// skill number the app can honestly produce without a dataset.
    private(set) var lastSkillReport: ForecastSkillReport?

    private let refresher: WeatherForecastRefresher

    /// The same reader the chart draws from, so the feature row and the picture are read off
    /// one curve and one cached offset rather than two that can disagree.
    private let forecast: PressureForecastReader

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
         forecast: PressureForecastReader,
         healthLog: any HealthSampleStore,
         calendar: Calendar = .current) {
        self.refresher = refresher
        self.forecast = forecast
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
            await readForecastQuality(asOf: now)
        }
    }

    /// Reads the feature row and the realised skill off the curve that just landed.
    ///
    /// **Only after rows land**, which the budget caps at four times a day plus the bootstrap.
    /// Two indexed store reads and a pass over 30 days of archived rows, on a wake the app was
    /// already granted — no new wake source, and nothing here powers a sensor, a radio or
    /// HealthKit. It is skipped entirely on the ordinary pass, where nothing is due.
    private func readForecastQuality(asOf now: Date) async {
        lastFeatures = await forecast.features(asOf: now)
        lastSkillReport = await forecast.skillReport(asOf: now)

        // Logged rather than shown. Nothing on screen may present model output as a claim
        // (`CLAUDE.md`, no medical claims + graded risk state only); this is the developer's
        // view of whether the forecast is earning its place, and §7 asks for it to be stated
        // whichever way it comes out.
        if let summary = lastSkillReport?.summary {
            BarosenseLog.pressure.info("forecast skill \(summary, privacy: .public)")
        }
        if let source = lastFeatures?.forecastSource {
            BarosenseLog.pressure.info(
                "forecast features from \(source.rawValue, privacy: .public)"
            )
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
