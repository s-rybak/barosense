import SwiftUI

@main
struct BarosenseApp: App {

    /// Composition root for HealthKit ingest. Profile / tag stores live in `AppServices`;
    /// the domain layer stays constructible from a test with doubles either way.
    private let ingest: HealthIngestController

    /// Composition root for barometer ingest. The phone receives what the watch sampled and
    /// never runs its own barometer — see `PressureIngestController` for why.
    private let pressure: PressureIngestController

    init() {
        let log: any HealthSampleStore
        do {
            log = try SwiftDataHealthSampleStore.makePersistent()
        } catch {
            // A store that cannot open must not take the app down with it. Fall back to
            // the in-memory double so the Now row still works; the training log simply
            // does not survive this launch. Surface this in Settings later — do not
            // crash on first paint.
            log = InMemoryHealthSampleStore()
        }

        let recorder = HealthSampleRecorder(reader: HealthKitDataReader(), log: log)
        let changeObserver: any HealthChangeObserving = HealthBackgroundDelivery.isEnabled
            ? HealthKitChangeObserver()
            : NoOpHealthChangeObserver()

        ingest = HealthIngestController(recorder: recorder, changeObserver: changeObserver)
        // Observers must exist before HealthKit delivers a background wake.
        ingest.start()

        let pressureLog: any PressureSampleStore
        do {
            pressureLog = try SwiftDataPressureSampleStore.makePersistent()
        } catch {
            // Same trade as above: the chart still draws whatever arrives this session, and
            // the watch keeps its own copy, so a failed open here costs continuity rather
            // than readings.
            pressureLog = InMemoryPressureSampleStore()
        }

        pressure = PressureIngestController(
            recorder: PressureSampleRecorder(source: UnavailablePressureSource(), log: pressureLog)
        )
        // The session must be live before WatchConnectivity delivers transfers queued while
        // the app was not running — that delivery is the only way the log ever grows.
        pressure.start()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(ingest: ingest, pressure: pressure)
        }
    }
}
