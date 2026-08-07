import SwiftUI

/// Root container: the selected destination with the custom tab bar pinned to the bottom.
struct RootView: View {

    let ingest: HealthIngestController
    let pressure: PressureCollectionController

    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .now

    var body: some View {
        ZStack {
            Palette.surface.ignoresSafeArea()

            // The remaining destinations are still placeholders. As a real screen lands,
            // add its case here and route to it.
            switch selection {
            case .now:
                NowScreen(recorder: ingest.recorder, pressure: pressure)
            case .history, .log, .insights, .settings:
                PlaceholderScreen(tab: selection)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BarosenseTabBar(selection: $selection)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                ingest.sceneDidBecomeActive()
                // The phone is the barometer now, and foreground activation is where most
                // of the log actually comes from — background wakes are granted sparsely.
                // Cheap to call on every activation: the recorder's fifteen-minute floor
                // decides whether the sensor runs at all.
                pressure.sceneDidBecomeActive()
            }
        }
        // Follow the system appearance; introduce a dark palette when the design system defines one.
    }
}

#Preview {
    RootView(ingest: HealthIngestController(
        recorder: HealthSampleRecorder(reader: HealthKitDataReader(),
                                       log: InMemoryHealthSampleStore()),
        changeObserver: NoOpHealthChangeObserver()),
             pressure: PressureCollectionController(
                recorder: PressureSampleRecorder(source: UnavailablePressureSource(),
                                                 log: InMemoryPressureSampleStore()),
                display: NoOpPressureDisplayLink()))
}
