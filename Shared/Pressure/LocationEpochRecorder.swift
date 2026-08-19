import Foundation

/// Keeps the epoch table in step with where the user actually is.
///
/// The sibling of `PressureSampleRecorder`, and the same shape: one object in front of a
/// store, holding the small piece of mutable state that is the whole point of it existing.
/// Here that state is "have we already geocoded this epoch" — the rule that keeps Apple's
/// throttled geocoder to **one call per place**, rather than one per activation.
///
/// ## Cost
///
/// 1. **What runs, how often?** One foreground activation → at most one fix. Nothing here is
///    reachable from a background wake (`LocationFixProviding`).
/// 2. **Work per activation?** With permission and an unchanged place: one fix and one
///    indexed store read. No geocode, no write. That is the ordinary day.
/// 3. **On a move past 25 km:** one extra store write, then one geocode, then one more write
///    to attach the name. A handful of times a year for most people.
/// 4. **Without permission:** nothing at all — no fix is requested, so no radio is powered.
///    The epoch already on disk is what the scheduler keeps using.
actor LocationEpochRecorder {

    private let access: any LocationAccessReporting
    private let fixes: any LocationFixProviding
    private let namer: any PlaceNaming
    private let store: any PressureLocationEpochStore

    /// Epochs whose one geocode has already been spent, whatever it returned.
    ///
    /// Keyed on epoch identity, not on coordinate, so an epoch the geocoder declined to name
    /// is not retried on every activation for the rest of the install. In memory rather than
    /// on disk, and deliberately: a fresh process may spend one more geocode on an epoch that
    /// came back empty, which is a cheap way to recover from "no network at the time" without
    /// a retry column in the schema.
    private var namedEpochIDs: Set<UUID> = []

    init(access: any LocationAccessReporting,
         fixes: any LocationFixProviding,
         namer: any PlaceNaming,
         store: any PressureLocationEpochStore) {
        self.access = access
        self.fixes = fixes
        self.namer = namer
        self.store = store
    }

    /// The epoch already on disk, with no fix requested and no radio powered.
    ///
    /// What a background wake uses. `currentEpoch(asOf:)` may ask CoreLocation for a fix, and
    /// a when-in-use app cannot start location updates from a `BGAppRefreshTask` — the attempt
    /// is documented to fail (`.claude/context/pressure-forecast-spec.md` §3, fact 4). So the
    /// background path reads what the last foreground session recorded, which is exactly the
    /// cached-coordinate design of §4.3 with no extra cache in it.
    func storedEpoch() async -> PressureLocationEpoch? {
        try? await store.currentEpoch()
    }

    /// The epoch new readings should be stamped with.
    ///
    /// Returns the stored epoch unchanged whenever nothing has moved, which is nearly always.
    /// Returns `nil` only when there is no epoch at all — a fresh install that has never been
    /// granted a fix — and a `nil` here never blocks a barometer reading: `PressureSample`
    /// carries an optional epoch id precisely so the sensor does not depend on the network or
    /// on a permission.
    ///
    /// Failures are swallowed for the same reason: an epoch is context for a reading, and
    /// losing the context must not lose the reading.
    @discardableResult
    func currentEpoch(asOf now: Date = .now) async -> PressureLocationEpoch? {
        let stored = try? await store.currentEpoch()

        // No permission, no fix requested. Reading the state first is what makes the refusal
        // free rather than a radio start that fails: `CLLocationManager` would answer the
        // same way, but only after being asked.
        guard await access.accessState().isGranted else { return stored }
        guard let fix = await fixes.currentFix() else { return stored }

        switch LocationEpochResolver.resolve(fix: fix.coordinate, against: stored) {
        case .reuse(let epoch):
            // Still the same place. The epoch may still be unnamed — a geocode that failed on
            // the day it opened — so this is where that one retry lands.
            return await namingIfNeeded(epoch)

        case .open(let coordinate):
            return await open(at: coordinate, altitudeMetres: fix.altitudeMetres, asOf: now)
        }
    }

    /// Writes a new epoch and spends its one geocode.
    ///
    /// The row is written **before** the geocode, not after. A reverse geocode is a throttled
    /// network round trip that can take seconds or never answer, and the forecast scheduler
    /// needs a coordinate, not a name — blocking the epoch on the name would make a slow
    /// geocoder look like a device that does not know where it is.
    private func open(at coordinate: GeoCoordinate,
                      altitudeMetres: Double?,
                      asOf now: Date) async -> PressureLocationEpoch {
        let epoch = PressureLocationEpoch(coordinate: coordinate,
                                          altitudeMetres: altitudeMetres,
                                          startedAt: now)
        try? await store.save(epoch)

        return await namingIfNeeded(epoch)
    }

    /// Geocodes an epoch once, ever.
    ///
    /// The guard is the acceptance criterion: Apple does not publish `CLGeocoder`'s limits,
    /// and an app that re-geocoded on every foreground activation would be throttled into
    /// returning nothing at all — which reads on screen as an app that has forgotten where it
    /// is.
    private func namingIfNeeded(_ epoch: PressureLocationEpoch) async -> PressureLocationEpoch {
        guard !namedEpochIDs.contains(epoch.id), epoch.place.isEmpty else { return epoch }
        namedEpochIDs.insert(epoch.id)

        guard let place = await namer.placeName(for: epoch.coordinate), !place.isEmpty else {
            return epoch
        }

        let named = epoch.namingPlace(place)
        try? await store.save(named)
        return named
    }
}
