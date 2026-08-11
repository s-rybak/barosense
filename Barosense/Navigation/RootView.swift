import SwiftUI

/// Root container: the selected destination with the custom tab bar pinned to the bottom.
struct RootView: View {

    let ingest: HealthIngestController
    let pressure: PressureCollectionController

    /// `nil` only while the store is still opening, which is a state this view is never
    /// shown in. Optional rather than force-unwrapped at the composition root.
    let settings: SettingsDependencies?
    let languages: LanguageController
    let onDataErased: () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .now

    /// Raised while Settings has something pushed. The pushed screens draw their own
    /// navigation bar and, in the design, no tab bar under them.
    @State private var isSettingsDetailPresented = false

    var body: some View {
        ZStack {
            Palette.surface.ignoresSafeArea()

            // The remaining destinations are still placeholders. As a real screen lands,
            // add its case here and route to it.
            switch selection {
            case .now:
                NowScreen(recorder: ingest.recorder, pressure: pressure)
            case .settings:
                if let settings {
                    SettingsScreen(dependencies: settings,
                                   languages: languages,
                                   isDetailPresented: $isSettingsDetailPresented,
                                   onDataErased: onDataErased)
                }
            case .history, .log, .insights:
                PlaceholderScreen(tab: selection)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isSettingsDetailPresented {
                BarosenseTabBar(selection: $selection)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSettingsDetailPresented)
        .onChange(of: selection) { _, tab in
            // Leaving Settings while a detail is pushed would otherwise strand the tab bar
            // hidden on a tab that has no way to bring it back.
            if tab != .settings { isSettingsDetailPresented = false }
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
                display: NoOpPressureDisplayLink()),
             settings: .preview,
             languages: LanguageController(),
             onDataErased: {})
}
