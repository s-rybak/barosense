import SwiftUI
import UserNotifications

@main
struct BarosenseApp: App {

    /// Composition root for HealthKit ingest. Profile / tag stores live in `AppServices`;
    /// the domain layer stays constructible from a test with doubles either way.
    private let ingest: HealthIngestController

    /// Composition root for barometer collection. The phone is the device with the sensor;
    /// the watch is a second screen onto it — see `PressureCollectionController` for why.
    private let pressure: PressureCollectionController

    /// The two sensor logs, kept here as well as inside the controllers. Settings needs
    /// them to erase the history, and re-opening the same store file a second time from
    /// there would be a second container over one SQLite file.
    private let healthLog: any HealthSampleStore
    private let pressureLog: any PressureSampleStore

    /// Where a tapped notification asks to go, and the delegate that records it.
    ///
    /// Both are held here for the same reason the ingest observers are started here: iOS
    /// delivers a tap that launched the app as soon as launching finishes, so the delegate has
    /// to be in place before that. `UNUserNotificationCenter.delegate` is also a weak reference,
    /// which makes holding the responder the difference between it working and it being
    /// deallocated on the next line.
    private let router = NotificationRouter()
    private let notificationResponder: NotificationResponder

    init() {
        let responder = NotificationResponder(router: router)
        UNUserNotificationCenter.current().delegate = responder
        notificationResponder = responder

        let log: any HealthSampleStore
        do {
            log = try SwiftDataHealthSampleStore.makePersistent()
        } catch {
            // A store that cannot open must not take the app down with it. Fall back to
            // the in-memory double so the Now row still works; the training log simply
            // does not survive this launch. Surface this in Settings later — do not
            // crash on first paint.
            //
            // Logged rather than swallowed: the Health row re-reads HealthKit on every
            // screen load, so this failure is invisible on screen and shows up only as a
            // training log that never grows.
            BarosenseLog.persistence.error(
                "health store unavailable, falling back to memory: \(String(describing: error), privacy: .public)"
            )
            log = InMemoryHealthSampleStore()
        }

        let recorder = HealthSampleRecorder(reader: HealthKitDataReader(), log: log)
        let changeObserver: any HealthChangeObserving = HealthBackgroundDelivery.isEnabled
            ? HealthKitChangeObserver()
            : NoOpHealthChangeObserver()

        healthLog = log
        ingest = HealthIngestController(recorder: recorder, changeObserver: changeObserver)
        // Observers must exist before HealthKit delivers a background wake.
        ingest.start()

        let pressureLog: any PressureSampleStore
        do {
            pressureLog = try SwiftDataPressureSampleStore.makePersistent()
        } catch {
            // Worse here than the Health fallback above. This is now the *only* copy of the
            // barometer history — no other device keeps one — so a failed open costs the
            // training log everything recorded before the next successful launch, and the
            // chart reads as if the sensor had never run. Hence the log line.
            BarosenseLog.persistence.error(
                "pressure store unavailable, falling back to memory: \(String(describing: error), privacy: .public)"
            )
            pressureLog = InMemoryPressureSampleStore()
        }

        self.pressureLog = pressureLog

        let link = WatchConnectivityPressureLink()
        link?.activate()

        pressure = PressureCollectionController(
            recorder: PressureSampleRecorder(source: CoreMotionPressureSource(), log: pressureLog),
            display: link ?? NoOpPressureDisplayLink()
        )
        // Takes the launch reading. The background chain is armed from the scene below,
        // not here — see `PressureCollectionController.armBackgroundRefresh`.
        pressure.start()
    }

    var body: some Scene {
        let pressure = pressure

        return WindowGroup {
            AppRootView(ingest: ingest,
                        pressure: pressure,
                        healthLog: healthLog,
                        pressureLog: pressureLog,
                        router: router)
                // The earliest point at which `.backgroundTask` below has registered the
                // identifier. Submitting before that raises an uncatchable ObjC exception.
                .task { pressure.armBackgroundRefresh() }
        }
        // The system holds the app awake for the length of this closure and suspends it the
        // moment the closure returns, so the reading and the durable write have to finish
        // inside it. `handleBackgroundRefresh` also re-arms the next wake.
        //
        // The identifier must match `BGTaskSchedulerPermittedIdentifiers` in the generated
        // Info.plist (`project.yml`); a mismatch fails at submit time, not here.
        .backgroundTask(.appRefresh(PressureSamplingPolicy.backgroundRefreshIdentifier)) {
            await pressure.handleBackgroundRefresh()
        }
    }
}
