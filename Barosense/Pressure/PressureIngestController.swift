import Foundation
import Observation

/// Owns the phone's side of the barometer link: receives what the watch took, writes it to
/// the training log, and tells the screen there is something new.
///
/// The phone does **not** sample. It has a barometer, and using it would look like free
/// coverage, but two devices at two altitudes writing into one series is the altitude
/// contamination of `.claude/context/ml-spec.md` §3 manufactured on purpose — the phone on a
/// desk and the watch three floors up disagree by several hPa, and nothing in the row says
/// which device it came from. One sensor, one series.
///
/// No battery note is needed here: this type starts nothing and polls nothing. It reacts to
/// deliveries WatchConnectivity was going to make anyway.
@MainActor
@Observable
final class PressureIngestController {

    /// Bumped after every batch that lands. The chart watches this rather than polling —
    /// a reading arriving while the user is looking at the screen should appear, and the
    /// alternative is a timer that runs whether or not anything changed.
    private(set) var lastIngestAt: Date?

    private let recorder: PressureSampleRecorder

    private var link: WatchConnectivityPressureLink?
    private var didStart = false

    init(recorder: PressureSampleRecorder) {
        self.recorder = recorder
    }

    /// Activates the WatchConnectivity session. Call once from the composition root.
    ///
    /// Not from a view: transfers queued while the phone app was not running are delivered
    /// shortly after activation, and a session that only activates when a particular screen
    /// appears would sit on that queue until the user happened to open it.
    func start() {
        guard !didStart else { return }
        didStart = true

        // Built here rather than in `init` so the handler can reference a fully initialised
        // `self`. `weak` because the link retains this closure and this object retains the
        // link; both live for the process lifetime, but a cycle that is only harmless by
        // accident is still a cycle.
        link = WatchConnectivityPressureLink { [weak self] samples in
            Task { await self?.receive(samples) }
        }
        link?.activate()
    }

    /// Rows the chart draws: the trailing window, ascending.
    func samples(trailing windowSeconds: TimeInterval) async -> [PressureSample] {
        (try? await recorder.samples(trailing: windowSeconds)) ?? []
    }

    /// Writes a delivered batch into the log.
    ///
    /// Failures are swallowed for the same reason they are on the Health path: the only
    /// things that can fail here are the store being unopenable and a corrupt payload, and
    /// neither is actionable from a screen. A silently missing hour looks exactly like the
    /// watch having been off, which the pipeline already handles.
    private func receive(_ samples: [PressureSample]) async {
        try? await recorder.ingest(samples)
        lastIngestAt = .now
    }
}
