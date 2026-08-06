import SwiftUI

@main
struct BarosenseApp: App {

    /// Composition root. Every protocol in `Shared/` gets its real implementation here and
    /// nowhere else, so the domain layer stays constructible from a test with doubles.
    private let ingest: HealthIngestController

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
    }

    var body: some Scene {
        WindowGroup {
            RootView(ingest: ingest)
        }
    }
}
