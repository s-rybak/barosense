import SwiftUI

/// Root container: the selected destination with the custom tab bar pinned to the bottom.
struct RootView: View {

    let ingest: HealthIngestController
    let pressure: PressureCollectionController
    let checkInStore: any CheckInStore
    let tagStore: any WellbeingTagStore

    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .now
    @State private var isLoggingCheckIn = false

    /// Bumped when a check-in is written, and handed to the chart as a reload trigger.
    ///
    /// A sheet does not rebuild what it covers, so without this the chart behind it keeps the
    /// markers it was built with and the new dot appears only after a tab change. Passed down
    /// rather than used to re-identify the destination: re-identifying also reloads the
    /// screen's own `@State`, which threw away the range the user had picked on the chart.
    @State private var checkInRevision = 0

    var body: some View {
        ZStack {
            Palette.surface.ignoresSafeArea()

            destination
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BarosenseTabBar(selection: tabBarSelection)
        }
        // The check-in is a sheet over whatever the user was looking at, not a destination
        // of its own (Figma `7:330` — the frame is drawn with a sheet's grab handle and no
        // tab bar). The raised centre action opens it; dismissing returns them where they
        // were.
        .sheet(isPresented: $isLoggingCheckIn) {
            LogScreen(checkInStore: checkInStore, tagStore: tagStore) {
                isLoggingCheckIn = false
                checkInRevision += 1
                // Onto the chart the new dot is already on. The one place the app moves the
                // user itself, and it is the point of the whole flow.
                selection = .now
            }
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

    /// The remaining destinations are still placeholders. As a real screen lands, add its
    /// case here and route to it.
    @ViewBuilder
    private var destination: some View {
        switch selection {
        // `.log` never lands here: `tabBarSelection` turns it into a sheet instead of
        // writing it. Folded in with `.now` rather than given a `default`, so a genuinely
        // new tab still has to be routed deliberately.
        case .now, .log:
            NowScreen(recorder: ingest.recorder,
                      pressure: pressure,
                      checkIns: checkInStore,
                      checkInRevision: checkInRevision)
        case .history, .insights, .settings:
            PlaceholderScreen(tab: selection)
        }
    }

    /// The bar's binding, with the raised centre action intercepted.
    ///
    /// Done here rather than in `BarosenseTabBar`: the bar's job is to report which item was
    /// tapped, and what a tap *means* is the root's decision. It also keeps the bar's
    /// selected-state highlight on the destination the user came from, which is what the
    /// frame shows while the sheet is up.
    private var tabBarSelection: Binding<AppTab> {
        Binding {
            selection
        } set: { tapped in
            if tapped == .log {
                isLoggingCheckIn = true
            } else {
                selection = tapped
            }
        }
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
             checkInStore: InMemoryCheckInStore(),
             tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds))
}
