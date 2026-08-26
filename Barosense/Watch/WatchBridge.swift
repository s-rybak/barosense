import Foundation

/// The phone's side of the watch link: what the watch is told, and what it sends back.
///
/// Both directions live in one type because they share one `WCSession` and because the
/// composition root should hand the rest of the app a single object for "the watch", not two
/// that have to be wired up in the right order.
///
/// ## Why an actor
///
/// Three callers on three different isolations reach it: `PressureCollectionController` on
/// the main actor after every reading, the root view on the main actor once the stores open,
/// and WatchConnectivity's own queue whenever a check-in lands. The state they all touch —
/// the last published context, the buffer of undelivered check-ins — is exactly the state
/// that must not be raced. Serialising it in one actor is cheaper and more obviously correct
/// than main-actor-hopping a callback that has no business being on the main actor.
///
/// ## Cost
///
/// Nothing recurring. No timer, no observer, no background task, no sensor. It reacts to a
/// reading the phone was already taking and to a delivery the system was already making, and
/// it publishes at most once per reading — see `WatchContextPolicy`, which drops a publish
/// that would tell the watch what it already knows.
actor WatchBridge {

    /// The publish side of the session, once `start()` has built one.
    ///
    /// Held as the protocol rather than as `WatchConnectivityPressureLink`, so a test can
    /// hand over a double and assert what this actor decides to put on the air. The concrete
    /// type is only needed to *activate* the session, which happens inside `start()` where it
    /// is still in hand.
    private var link: (any WatchContextLink)?

    /// The last pressure the phone measured, held so a later tag update can be published
    /// alongside it rather than replacing it. The context is one slot: whoever publishes has
    /// to publish the whole of it.
    private var pressure: PressureDisplaySnapshot?

    private var tags: [WatchTag] = []

    /// What the watch was last told. In memory, and only ever compared against — a publish
    /// skipped because nothing changed is not worth remembering across launches.
    private var lastPublished: WatchContext?

    private var checkInStore: (any CheckInStore)?

    /// Held rather than read once, so `refreshTags()` has somewhere to read *from*. The
    /// vocabulary changes under the watch at two moments the phone knows about and the watch
    /// cannot — an Edit Profile save, and "delete my data" — and both need the current list,
    /// not the one that was current when the stores opened.
    private var tagStore: (any WellbeingTagStore)?

    /// Check-ins that arrived before the store was open.
    ///
    /// A real window, not a theoretical one: `transferUserInfo` delivers queued items shortly
    /// after activation, and activation happens in `App.init` while the SwiftData container
    /// is still being opened a few hundred milliseconds later.
    ///
    /// **Residual risk, stated rather than engineered away.** WatchConnectivity has no
    /// acknowledgement for a user-info transfer, so an item is off the system's queue the
    /// moment it is handed over. If the store never opens and the process is killed, anything
    /// in here is lost. The mitigation is that `AppServices.start()` can be retried from the
    /// failure screen and this buffer survives the retry, since it is process-lifetime state
    /// and the process is what the user is being asked to keep alive. Persisting the buffer
    /// separately would mean a second on-disk store for health data, which is a bigger
    /// decision than this one.
    private var buffered: [WatchCheckIn] = []

    /// Ceiling on the buffer, so a store that never opens cannot grow it without bound.
    ///
    /// Far above anything reachable — it would take a hundred check-ins entered on the watch
    /// while the phone's store was broken — and the overflow drops the *oldest*, because if
    /// something has to be lost it should be the report the user is least likely to still
    /// care about.
    static let maxBuffered = 100

    /// `link` is normally built by `start()`; a test hands one over instead, which also makes
    /// `start()` the no-op it should be when there is no session to bring up.
    init(link: (any WatchContextLink)? = nil) {
        self.link = link
    }

    /// Builds and activates the session. Call once, from the root view's `task`.
    ///
    /// Not from `App.init`, for the same reason `armBackgroundRefresh` is not: the earliest
    /// point where the app is a running scene rather than a half-built one. Idempotent.
    func start() async {
        guard link == nil else { return }

        // `weak` because the link retains this closure and this object retains the link.
        // Both live for the process lifetime, but a cycle that is only harmless by accident
        // is still a cycle.
        let connectivity = WatchConnectivityPressureLink(
            onReceiveCheckIn: { [weak self] checkIn in
                Task { await self?.receive(checkIn) }
            }
        )
        guard let connectivity else {
            // An iPad or a Mac running the app: nothing to pair with. The phone keeps
            // sampling into its own log and the only thing lost is a second screen.
            BarosenseLog.pressure.info("WatchConnectivity unsupported here, no watch link")
            return
        }
        connectivity.activate()
        link = connectivity

        // Whatever arrived before the link existed goes out now. The launch reading is
        // routinely one of them: `PressureCollectionController.start()` runs in `App.init`.
        //
        // Usually there is nothing yet — this runs milliseconds into the scene and the first
        // reading takes about a second — and that is exactly the case `WatchContextPolicy`
        // refuses, because publishing nothing would replace the watch's persisted reading
        // with nothing. Left as a call rather than deleted: when the reading *has* already
        // landed, this is what puts it on the air a second earlier.
        await publishIfChanged()
    }

    /// Hands over the stores, once `AppServices` has opened them.
    ///
    /// Two jobs at once because they are the same event: the point at which the phone can
    /// both answer "which tags does this user have" and accept a check-in from the watch.
    func attach(checkInStore: any CheckInStore, tagStore: any WellbeingTagStore) async {
        self.checkInStore = checkInStore
        self.tagStore = tagStore

        await refreshTags()
        await drainBuffer()
    }

    // MARK: - Phone → watch

    /// Re-reads the vocabulary and republishes it.
    ///
    /// Three callers, and they are the three moments the phone's tag list can move under a
    /// watch that has no way to notice: the stores opening (`attach`), an Edit Profile save,
    /// and "delete my data".
    ///
    /// The last of those is the one that makes this a correctness fix rather than a polish
    /// one. An erase drops the vocabulary and onboarding re-seeds it, but the watch's copy is
    /// in a persisted context slot — so without this the user's own tag names survive on their
    /// wrist after they asked for them to be gone. The Edit Profile case is milder: a tag
    /// archived on the phone stays on a chip, and choosing it files against an archived tag,
    /// which resolves and is merely stale.
    ///
    /// Reads the store rather than taking a list, because the erase path has no list to hand
    /// over — it has a store that has just been emptied and re-seeded.
    func refreshTags() async {
        guard let tagStore else { return }

        // A vocabulary that will not load costs the watch its chips and nothing else — the
        // intensity is what makes a check-in, and that form stays usable without tags.
        tags = WatchTag.offered(from: (try? await tagStore.activeTags()) ?? [])
        await publishIfChanged()
    }

    private func publishIfChanged() async {
        let context = WatchContext(pressure: pressure, tags: tags)

        guard WatchContextPolicy.shouldPublish(context, lastPublished: lastPublished) else {
            return
        }
        guard let link else { return }

        await link.publish(context)
        lastPublished = context
    }

    // MARK: - Watch → phone

    /// A check-in the watch queued. Arrives on WatchConnectivity's queue, possibly hours
    /// after it was made and possibly more than once.
    ///
    /// Redelivery is handled by the store rather than by a seen-set here: `CheckInStore.save`
    /// replaces on matching `id`, and the identifier was generated on the watch and travels
    /// unchanged, so the same report lands on the same row.
    func receive(_ checkIn: WatchCheckIn) async {
        guard let checkInStore else {
            buffer(checkIn)
            return
        }

        await write(checkIn, to: checkInStore)
    }

    /// The one way onto the buffer, so the ceiling applies to every path that grows it.
    ///
    /// Both callers can repeat without bound — a store that has not opened yet and a store
    /// that will not write are the same shape of failure from here — and a cap enforced on
    /// only one of them is not a cap.
    private func buffer(_ checkIn: WatchCheckIn) {
        if buffered.count >= Self.maxBuffered {
            BarosenseLog.persistence.error("watch check-in buffer full, dropping the oldest")
            buffered.removeFirst()
        }
        buffered.append(checkIn)
    }

    private func drainBuffer() async {
        guard let checkInStore, !buffered.isEmpty else { return }

        let queued = buffered
        buffered = []
        for checkIn in queued {
            await write(checkIn, to: checkInStore)
        }
    }

    /// A failed write is a report the user made that the app does not have.
    ///
    /// Put back on the buffer rather than logged and forgotten, so a retry from the store
    /// failure screen picks it up. Not retried in a loop here: the failure that produces it
    /// is a store that will not write, and hammering it inside an actor the sampler also
    /// waits on would make one broken subsystem into two.
    private func write(_ checkIn: WatchCheckIn, to store: any CheckInStore) async {
        do {
            try await store.save(checkIn.checkIn)
        } catch {
            BarosenseLog.persistence.error(
                "a check-in from the watch could not be saved: \(String(describing: error), privacy: .public)"
            )
            buffer(checkIn)
        }
    }
}

// MARK: - Pressure sink

/// Receives every reading the phone takes and folds it into the watch's context.
///
/// `PressureCollectionController` publishes a `PressureDisplaySnapshot` and knows nothing
/// about tags or check-ins, which is why it still talks to the narrow protocol and this type
/// is what widens it. That keeps the sampler's contract exactly as small as its job.
extension WatchBridge: PressureDisplayLink {

    func publish(_ snapshot: PressureDisplaySnapshot) async {
        pressure = snapshot
        await publishIfChanged()
    }
}
