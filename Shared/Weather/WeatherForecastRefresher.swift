import Foundation

/// Decides whether to ask WeatherKit anything, and files what comes back.
///
/// Every gate the feature has lives here, in one readable order: the shipped kill switch, the
/// user's switch, the location permission, whether there is a coordinate at all, and finally
/// the slot budget. Each of them ends the pass without a request, which is what makes "zero
/// network calls when it is off" a property that can be tested rather than reviewed.
///
/// An `actor` because it holds the one piece of mutable state a refresh needs — when it last
/// ran retention — and because two activations can land within milliseconds of each other.
///
/// ## Cost
///
/// 1. **Wake source:** none of its own. It runs on a foreground activation and inside the
///    barometer's existing `BGAppRefreshTask`. `CLAUDE.md` constraint 4 is satisfied by there
///    being no new wake rather than by a cheap one.
/// 2. **Work per pass, nothing due:** one indexed store read of today's issue times. No
///    network, no radio, no location.
/// 3. **Work per pass, a slot due:** one `weather(for:including:)` — one unit of quota — and
///    one batched write of ~240 rows.
/// 4. **Once per install:** one extra historical request, so the day WeatherKit is first
///    switched on can make five calls rather than four. Bounded twice: the success is recorded
///    durably, and a failure is not retried again until the next launch.
/// 5. **Powered while awake:** the network, for the length of one request. Never the barometer
///    and never CoreLocation — the coordinate is read from the epoch table.
actor WeatherForecastRefresher {

    /// What a pass did. Returned so a caller — or a test — can tell "did not ask" from "asked
    /// and got nothing", which are different facts with different fixes.
    enum Outcome: Equatable {

        /// The shipped kill switch is off.
        case disabled

        /// The trade has not been explained yet, so nothing may go out on the user's behalf.
        ///
        /// The preference ships **on**, which is what makes this gate necessary rather than
        /// redundant: without it, a default-on switch could put a request on the network
        /// before the screen that explains it has ever been on screen. It clears on the first
        /// launch after this feature ships, whichever way the user answers.
        case notYetExplained

        /// The user turned WeatherKit off. The archive is left exactly as it is: switching
        /// back on must not pay a cold start again (§5, PR 2, criterion 4).
        case switchedOff

        /// The location grant is missing or was revoked. **No slot is spent** — the day's
        /// allowance is not burned on requests that could not have been made.
        case noLocationAccess

        /// Granted, but no epoch yet: a fresh install whose first fix has not landed.
        case noLocation

        /// Nothing is due. The ordinary outcome of most activations.
        case notDue

        /// Rows were written. `points` counts them, `wasBootstrap` says whether the historical
        /// request ran in the same pass.
        case refreshed(points: Int, wasBootstrap: Bool)

        /// WeatherKit refused. Ordinary in the Simulator, which does not serve it at all.
        case failed
    }

    private let provider: any WeatherForecastProviding
    private let store: any WeatherForecastStore
    private let epochs: any PressureLocationEpochStore
    private let access: any LocationAccessReporting
    private let preferences: any WeatherKitPreferenceStore
    private let budget: WeatherRequestBudget
    private let calendar: Calendar

    /// When this instance last checked the retention horizon. In memory, like
    /// `PressureSampleRecorder`'s, and with the same consequence: a fresh process prunes on its
    /// first write, which is the cadence wanted for a horizon that moves a day per day.
    private var lastPrunedAt: Date?

    /// Whether this instance has already spent a request on the history bootstrap.
    ///
    /// In memory, and that is the point: the durable check in `bootstrapIfNeeded` can only see
    /// a bootstrap that *landed*, so a location whose history WeatherKit declines to serve
    /// would retry on every due slot forever. This bounds that to one extra request per launch,
    /// while a genuine network failure still gets another attempt the next time the app starts.
    private var didAttemptBootstrap = false

    init(provider: any WeatherForecastProviding,
         store: any WeatherForecastStore,
         epochs: any PressureLocationEpochStore,
         access: any LocationAccessReporting,
         preferences: any WeatherKitPreferenceStore,
         budget: WeatherRequestBudget = WeatherRequestBudget(),
         calendar: Calendar = .current) {
        self.provider = provider
        self.store = store
        self.epochs = epochs
        self.access = access
        self.preferences = preferences
        self.budget = budget
        self.calendar = calendar
    }

    /// How far back the bootstrap reaches.
    ///
    /// Seven days, which is WeatherKit's ten-day per-request limit with room to spare, and
    /// enough overlap with an existing barometer log for `PressureOffsetCalibrator` to measure
    /// the station-to-MSLP offset on the day the switch is first turned on. The barometer has
    /// been recording since the app was installed; WeatherKit is switched on later, so on that
    /// day there is a week of station pressure sitting on disk with nothing to compare it to.
    static let bootstrapDays = 7

    /// One pass.
    ///
    /// `wakeTime` moves the first slot of the day and comes from `.sleepAnalysis`, which is
    /// already authorised and already read. It reaches **only** the slot arithmetic: there is
    /// no path from it to the request payload, which is a coordinate and a time.
    @discardableResult
    func refresh(asOf now: Date = .now, wakeTime: Date? = nil) async -> Outcome {
        guard WeatherForecastPolicy.isEnabled else { return .disabled }
        guard preferences.hasOfferedWeatherKit() else { return .notYetExplained }
        guard preferences.isWeatherKitEnabled() else { return .switchedOff }

        // Before the budget, deliberately. A revoked grant must leave the day's slots
        // untouched rather than spend them on calls that cannot succeed (§4.10, decision 3).
        guard await access.accessState().isGranted else { return .noLocationAccess }

        // The epoch table is the coordinate cache. Nothing here asks CoreLocation for a fix:
        // a background wake could not take one anyway, and a foreground pass already resolved
        // the epoch on the way in (`LocationEpochRecorder`).
        // `try?` flattens the store's optional return, so one binding covers both "the store
        // refused" and "there is no epoch yet". Neither is worth distinguishing: both mean
        // there is no coordinate to ask about, and the local model is what covers that.
        guard let epoch = try? await epochs.currentEpoch() else { return .noLocation }

        let issues = (try? await store.issueTimes(in: budget.day(containing: now,
                                                                 calendar: calendar))) ?? []
        guard budget.admitsRequest(asOf: now,
                                   given: issues,
                                   calendar: calendar,
                                   wakeTime: wakeTime) else {
            return .notDue
        }

        return await request(for: epoch.coordinate, asOf: now)
    }

    /// The network half, once every gate has said yes.
    private func request(for coordinate: GeoCoordinate, asOf now: Date) async -> Outcome {
        var written = 0
        let wasBootstrap = await bootstrapIfNeeded(for: coordinate, asOf: now, written: &written)

        do {
            let issue = try await provider.forecast(for: coordinate, asOf: now)
            try await store.save(issue.points)
            written += issue.points.count
        } catch {
            BarosenseLog.pressure.info(
                "weather forecast request failed: \(String(describing: error), privacy: .public)"
            )
            // A bootstrap that landed is still progress worth reporting, and its rows are
            // already durable.
            return wasBootstrap && written > 0 ? .refreshed(points: written, wasBootstrap: true)
                                               : .failed
        }

        await pruneExpiredArchive(asOf: now)

        return .refreshed(points: written, wasBootstrap: wasBootstrap)
    }

    /// One historical request, once per install.
    ///
    /// The window ends at **the start of today**, not at `now`, and that is not cosmetic:
    /// historical rows are stored with `issuedAt == validAt`, so rows describing hours earlier
    /// today would read as today's issues and inflate the request count this same budget is
    /// enforced from. Ending at midnight puts every one of them outside the day being counted.
    ///
    /// **"Already bootstrapped" is recorded, not inferred.** Both obvious inferences are wrong.
    /// "The seven-day window holds rows" reads as true the day after a bootstrap that *failed*,
    /// because the window moves and yesterday's ordinary forecast rows slide into it — one
    /// network hiccup and the install never bootstraps again. "A row with `issuedAt == validAt`"
    /// is not a marker either: a forecast's own zero-lead point is knowable at the hour it
    /// describes, exactly as an observation is. So the fact is written down when it happens,
    /// and cross-checked against the archive still existing.
    private func bootstrapIfNeeded(for coordinate: GeoCoordinate,
                                   asOf now: Date,
                                   written: inout Int) async -> Bool {
        // One attempt per process, on top of the durable check below. A coordinate whose
        // history WeatherKit will not serve would otherwise spend an extra request on every
        // due slot for the life of the install — the durable check can only see a bootstrap
        // that succeeded.
        guard !didAttemptBootstrap else { return false }

        let startOfToday = calendar.startOfDay(for: now)
        guard let earliest = calendar.date(byAdding: .day, value: -Self.bootstrapDays,
                                           to: startOfToday),
              earliest < startOfToday else {
            return false
        }

        let window = earliest..<startOfToday
        // The recorded fact, cross-checked against the rows it describes. "Delete my data" wipes
        // the archive without touching preferences — deliberately, since a preference holds
        // nothing personal — and a flag remembering a bootstrap whose rows are gone would leave
        // that install permanently without one.
        let existing = (try? await store.points(issuedAtOrBefore: now, validIn: window)) ?? []
        if preferences.hasBootstrappedHistory(), !existing.isEmpty { return false }

        didAttemptBootstrap = true

        do {
            let observations = try await provider.history(for: coordinate, in: window)
            guard !observations.isEmpty else { return false }

            let points = observations.map { $0.asArchivedPoint() }
            try await store.save(points)
            written += points.count
            preferences.setHasBootstrappedHistory(true)
            return true
        } catch {
            // A failed bootstrap is not a failed pass. The forecast request that follows is the
            // part the user sees; the history only sharpens the offset calibration, and it will
            // be attempted again on the next launch — not the next slot, because a location
            // whose history the service simply does not serve must not spend a request an hour
            // asking again.
            BarosenseLog.pressure.info(
                "weather history bootstrap failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// Drops raw rows past the 90-day horizon, at most once a day.
    ///
    /// Hung off the write path rather than given a wake of its own, exactly as
    /// `PressureSampleRecorder.pruneExpiredHistory` is: the archive only grows when a request
    /// lands, so the one moment retention can be needed is just after one did.
    ///
    /// Failure is swallowed. The rows just written are already durable, and a retention pass
    /// that could not run costs disk space rather than data.
    private func pruneExpiredArchive(asOf now: Date) async {
        if let lastPrunedAt,
           now.timeIntervalSince(lastPrunedAt) < PressureRetentionPolicy.pruneIntervalSeconds {
            return
        }
        lastPrunedAt = now

        do {
            let cutoff = WeatherForecastPolicy.rawCutoff(asOf: now, calendar: calendar)
            let dropped = try await store.deletePoints(validBefore: cutoff)
            if dropped > 0 {
                BarosenseLog.persistence.info(
                    "weather archive retention dropped \(dropped, privacy: .public) rows"
                )
            }
        } catch {
            BarosenseLog.persistence.error(
                "weather archive retention failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
