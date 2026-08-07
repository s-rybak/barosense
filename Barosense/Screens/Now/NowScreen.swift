import SwiftUI

/// The Now destination (Figma `7:632`).
///
/// The pressure chart and the Health card row are built, in the design's own order. The rest
/// of the screen it draws — the risk card above the chart, the two progress cards below the
/// row — is still `PlaceholderScreen` territory and lands separately; this file grows a
/// section at a time.
struct NowScreen: View {

    @State private var model: HealthMetricsViewModel

    private let pressure: PressureCollectionController
    private let checkIns: any CheckInStore

    /// Side margin the design uses for every card on this screen: 20 pt inside a 351 pt
    /// frame.
    private static let horizontalMargin: CGFloat = 20

    /// Gap between two cards: 494 − (234 + 246) in the design's own coordinates.
    private static let cardSpacing: CGFloat = 14

    init(recorder: HealthSampleRecorder,
         pressure: PressureCollectionController,
         checkIns: any CheckInStore) {
        _model = State(initialValue: HealthMetricsViewModel(recorder: recorder))
        self.pressure = pressure
        self.checkIns = checkIns
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.cardSpacing) {
                PressureChartCard(collection: pressure, checkIns: checkIns)

                VStack(alignment: .leading, spacing: 12) {
                    HealthMetricsRow(snapshot: model.snapshot)

                    if model.showsEmptyNote {
                        Text("Поки немає даних з Health")
                            .font(Typography.cardNote)
                            .foregroundStyle(Palette.inkSubtle)
                    }
                }
            }
            .padding(.horizontal, Self.horizontalMargin)
            .padding(.top, Self.horizontalMargin)
        }
        // `.task` rather than `.onAppear`: the read is async and gets cancelled with the
        // view instead of outliving it.
        .task { await model.load() }
        .refreshable { await model.reload() }
    }
}

/// State behind the Health card row.
///
/// Holds no domain logic — it moves the snapshot from `HealthSampleRecorder` onto the main
/// actor and decides nothing about what the numbers mean. That decision lives in
/// `HealthMetricsSnapshot.make`, in `Shared/`, where a test can reach it.
@MainActor
@Observable
final class HealthMetricsViewModel {

    private(set) var snapshot: HealthMetricsSnapshot = .empty

    private let recorder: HealthSampleRecorder
    private var hasLoaded = false

    init(recorder: HealthSampleRecorder) {
        self.recorder = recorder
    }

    /// True once a read has finished and come back with nothing.
    ///
    /// Deliberately not shown before the first read completes: an empty row plus a note
    /// during the first few hundred milliseconds would say "no data" to a user who has
    /// plenty.
    var showsEmptyNote: Bool { hasLoaded && snapshot.isEmpty }

    /// First read of the session: ask for access, then refresh. Idempotent, because
    /// `.task` re-runs whenever the view is rebuilt.
    func load() async {
        guard !hasLoaded else { return }
        try? await recorder.authorize()
        await reload()
    }

    /// Re-reads the Health store and writes what it read into the training log.
    ///
    /// A failure is swallowed into an empty snapshot on purpose. Every reason this can
    /// fail — no Health store on the device, access not granted, nothing recorded — is a
    /// state the user cannot act on from this screen, and all of them look identical from
    /// here by design (`.claude/skills/healthkit_permissions/SKILL.md`). The error carries
    /// no health values, so there is nothing to report and nowhere to report it.
    func reload() async {
        snapshot = (try? await recorder.refresh()) ?? .empty
        hasLoaded = true
    }
}

#Preview {
    NowScreen(recorder: HealthSampleRecorder(reader: PreviewHealthDataReader(),
                                             log: InMemoryHealthSampleStore()),
              pressure: PressureCollectionController(
                recorder: PressureSampleRecorder(source: UnavailablePressureSource(),
                                                 log: InMemoryPressureSampleStore()),
                display: NoOpPressureDisplayLink()),
              checkIns: InMemoryCheckInStore())
    .background(Palette.surface)
}

/// Fixed readings so the preview renders the populated row without a Health store.
private struct PreviewHealthDataReader: HealthDataReader {

    func requestAuthorization() async throws {}

    func samples(of kind: HealthMetricKind, in range: Range<Date>) async throws -> [HealthSample] {
        let now = Date.now
        switch kind {
        case .restingHeartRate:
            return [HealthSample(id: UUID(), start: now, end: now, value: .restingHeartRateBPM(62))]
        case .oxygenSaturation:
            return [HealthSample(id: UUID(), start: now, end: now, value: .oxygenSaturationFraction(0.97))]
        case .asleep:
            let woke = now.addingTimeInterval(-2 * 3600)
            return [HealthSample(id: UUID(),
                                 start: woke.addingTimeInterval(-(7 * 3600 + 20 * 60)),
                                 end: woke,
                                 value: .asleep)]
        }
    }
}
