import SwiftUI

@main
struct BarosenseWatchApp: App {

    /// Composition root for barometer collection. The one place that knows the log is
    /// SwiftData and the sensor is CoreMotion; everything below takes protocols.
    private let collector: PressureCollectionController

    init() {
        let log: any PressureSampleStore
        do {
            log = try SwiftDataPressureSampleStore.makePersistent()
        } catch {
            // A store that cannot open must not take the app down with it. Fall back to the
            // in-memory double so sampling and the uplink still work for this launch; what
            // is lost is the resend window, not the readings themselves — each one is still
            // handed to the phone as it is taken.
            log = InMemoryPressureSampleStore()
        }

        let recorder = PressureSampleRecorder(source: CoreMotionPressureSource(), log: log)

        let link = WatchConnectivityPressureLink()
        link?.activate()
        let uplink: any PressureSampleUplink = link ?? NoOpPressureSampleUplink()

        collector = PressureCollectionController(recorder: recorder, uplink: uplink)
        collector.start()
    }

    var body: some Scene {
        let collector = collector

        return WindowGroup {
            WatchRootView(collector: collector)
        }
        // The system holds the app awake for the length of this closure and suspends it the
        // moment the closure returns, so the reading and the durable write have to finish
        // inside it. `handleBackgroundRefresh` also re-arms the next wake.
        .backgroundTask(.appRefresh) { _ in
            await collector.handleBackgroundRefresh()
        }
    }
}

/// The watch app's only screen: the last reading this watch took.
///
/// One number and its unit, nothing else — a watch screen is read in about half a second
/// (`.claude/skills/watchos_budget/SKILL.md`). The history it is accumulating is shown on
/// the phone, where there is room for a chart.
struct WatchRootView: View {

    let collector: PressureCollectionController

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "barometer")
                .font(.footnote)
                .foregroundStyle(.tint)

            Text(reading)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                collector.sceneDidBecomeActive()
            }
        }
    }

    /// The dash is the ordinary state on a device with no barometer, and while the first
    /// reading is still in flight. Neither is an error worth wording.
    private var reading: String {
        guard let hectopascals = collector.latest?.pressure.hectopascals else { return "—" }
        return PressureFormat.roundedHectopascals(hectopascals)
    }

    private var unit: String {
        collector.latest == nil && collector.hasAttemptedSample ? "немає даних" : "гПа"
    }
}

#Preview {
    WatchRootView(collector: PressureCollectionController(
        recorder: PressureSampleRecorder(source: UnavailablePressureSource(),
                                         log: InMemoryPressureSampleStore()),
        uplink: NoOpPressureSampleUplink()))
}
