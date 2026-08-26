import SwiftUI

@main
struct BarosenseWatchApp: App {

    /// Composition root for the watch. Short, because the watch owns very little: no store,
    /// no sensor, no background refresh — one link to the phone, the state it delivers, and
    /// a queue for the one thing that travels the other way.
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

/// Where a push from the main screen goes.
///
/// A value-routed `NavigationStack` rather than nested `NavigationLink` destinations, so the
/// screens stay independently previewable and the check-in form can pop itself on save
/// without its parent knowing it did.
enum WatchRoute: Hashable {
    case trend
    case details
    case log
}

/// The watch app's navigation root.
///
/// The main screen is one number read in about half a second
/// (`.claude/skills/watchos_budget/SKILL.md`); everything with more in it is a push away, so
/// nothing competes with the number for the glance.
struct WatchRootView: View {

    let display: PressureDisplayController

    @Environment(\.scenePhase) private var scenePhase

    @State private var path: [WatchRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if display.snapshot == nil && !display.hasSettled {
                    WatchLoadingView()
                } else {
                    WatchNowView(display: display)
                }
            }
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .trend:
                    WatchTrendView(snapshot: display.snapshot)
                case .details:
                    WatchDetailsView(snapshot: display.snapshot)
                case .log:
                    WatchLogView(tags: display.tags, link: display.checkInLink)
                }
            }
        }
        .tint(WatchPalette.chartLineOnDark)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                display.sceneDidBecomeActive()
            }
        }
    }
}

// MARK: - W0

/// Shown for the moment between launch and the session handing over whatever it kept
/// (Figma `W0`).
///
/// Brief — `receivedApplicationContext` is read as soon as activation completes — but not
/// instantaneous, and a dash that turns into a number reads as a broken sensor where a load
/// state reads as a load.
///
/// Deliberately the same composition as the phone's opening phase: the app mark on the app's
/// own surface, with one indeterminate indicator and no copy. Two devices launching the same
/// app should not disagree about what launching looks like, and there is nothing truthful to
/// say here anyway — the wait is not long enough to caption, and naming a cause ("waiting for
/// iPhone") would be wrong on the launch where the context was already there.
struct WatchLoadingView: View {

    /// Drives the ring. One `withAnimation`-free repeating rotation, which the system stops
    /// paying for the moment the view leaves the hierarchy — and this view is on screen for
    /// well under a second in the ordinary case.
    ///
    /// No timer and nothing scheduled: this is Core Animation turning a transform on an
    /// already-lit screen, which the battery budget counts as free — the alternative is a
    /// static screen for the same duration, not a sleeping one.
    @State private var isSpinning = false

    private enum Metrics {
        static let mark: CGFloat = 58
        /// Centre-to-centre radius of the dot ring. Outside the mark with a clear gap, so the
        /// two read as a mark and an indicator rather than as one crowded emblem.
        static let ringRadius: CGFloat = 42
        static let dot: CGFloat = 3.5
        static let dots = 8
        static let period: TimeInterval = 1.6
    }

    var body: some View {
        ZStack {
            WatchPalette.surface.ignoresSafeArea()

            ZStack {
                dotRing

                BarosenseLogoMark(size: Metrics.mark)
            }
        }
        .onAppear {
            // `withAnimation` here rather than an `.animation(_:value:)` on the ring, and the
            // difference is visible rather than stylistic. That modifier animates *every*
            // animatable change in its subtree when the value flips — including each dot's
            // static offset, which on first appearance counts as a change from zero. Paired
            // with `repeatForever` the offsets then never settle: the dots fly outwards from
            // the centre and restart, which reads as a scatter rather than a ring.
            withAnimation(.linear(duration: Metrics.period).repeatForever(autoreverses: false)) {
                isSpinning = true
            }
        }
        // One element saying what is happening, rather than eight dots and a mark. The mark
        // itself is decorative and hides from VoiceOver on its own.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    /// Dots rather than `ProgressView`: at this diameter the system's circular indicator
    /// draws a hairline ring that reads as part of the mark's own geometry, and the two
    /// rings then look like one ring that is slightly wrong.
    private var dotRing: some View {
        ZStack {
            ForEach(0..<Metrics.dots, id: \.self) { index in
                Circle()
                    .fill(WatchPalette.ink)
                    // Fading around the ring is what gives the rotation a direction. The
                    // floor is not zero: a dot that vanishes entirely makes the ring look
                    // like it has a missing piece rather than a leading edge.
                    .opacity(0.15 + 0.85 * (Double(index) / Double(Metrics.dots)))
                    .frame(width: Metrics.dot, height: Metrics.dot)
                    .offset(offset(at: index))
            }
        }
        // An explicit square the size of the ring, so the dots orbit *this* view's centre.
        // Without it the stack sizes to one dot and the rotation below turns a 3.5 pt frame
        // whose content sticks out well past it, which is how the ring ends up off-centre.
        .frame(width: Metrics.ringRadius * 2, height: Metrics.ringRadius * 2)
        .rotationEffect(.degrees(isSpinning ? 360 : 0))
    }

    /// Where dot `index` sits, from the ring's centre. Trigonometry rather than a per-dot
    /// `rotationEffect`, because that modifier turns a view about its own frame and the frame
    /// here is one dot — the result is eight dots each spun in place at a different angle,
    /// which is not a ring.
    private func offset(at index: Int) -> CGSize {
        let angle = Double(index) / Double(Metrics.dots) * 2 * .pi - .pi / 2
        return CGSize(width: Metrics.ringRadius * cos(angle),
                      height: Metrics.ringRadius * sin(angle))
    }
}

#Preview("W0 · Loading") {
    WatchLoadingView()
}

#Preview("Root · falling") {
    WatchRootView(display: .previewing(.previewFalling()))
}
