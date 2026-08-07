import SwiftUI

@main
struct BarosenseWatchApp: App {

    /// Composition root for the watch. Short, because the watch owns nothing: no store, no
    /// sensor, no background refresh — one link to the phone and the value it delivers.
    private let display = PressureDisplayController()

    init() {
        // The session must be live before WatchConnectivity hands over a context published
        // while this app was not running — that delivery is the only way the screen updates.
        display.start()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(display: display)
        }
    }
}

/// The watch app's only screen: the pressure the phone last measured.
///
/// One number and its unit, nothing else — a watch screen is read in about half a second
/// (`.claude/skills/watchos_budget/SKILL.md`). The history it belongs to is shown on the
/// phone, where there is room for a chart.
struct WatchRootView: View {

    let display: PressureDisplayController

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

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                display.sceneDidBecomeActive()
            }
        }
    }

    /// The dash is the ordinary state until the phone's first reading arrives. Not an error
    /// worth wording: a fresh install, a phone out of range, and a phone that has simply not
    /// sampled yet all look the same from here and all resolve themselves.
    private var reading: String {
        guard let hectopascals = display.snapshot?.sample.pressure.hectopascals else { return "—" }
        return PressureFormat.roundedHectopascals(hectopascals)
    }

    /// The unit, plus the two things that would otherwise be a lie.
    ///
    /// **The tendency**, because an arrow costs no space and is the one piece of context a
    /// bare number lacks. **The age**, whenever the reading is older than the phone's own
    /// sampling floor: a watch out of range for a day would otherwise present yesterday's
    /// pressure as the current one, and the user has no way to tell.
    private var caption: String {
        guard let snapshot = display.snapshot else { return "чекаю телефон" }

        var parts = ["гПа"]
        if let arrow = Self.arrow(for: snapshot.trend) {
            parts.append(arrow)
        }

        let age = Date.now.timeIntervalSince(snapshot.sample.timestamp)
        if age > PressureSamplingPolicy.minimumIntervalSeconds {
            parts.append(snapshot.sample.timestamp.formatted(.relative(presentation: .numeric)))
        }

        return parts.joined(separator: " · ")
    }

    private static func arrow(for trend: PressureTrend) -> String? {
        switch trend {
        case .rising: "↗"
        case .falling: "↘"
        case .steady: "→"
        case .unknown: nil
        }
    }
}

#Preview {
    WatchRootView(display: PressureDisplayController())
}
