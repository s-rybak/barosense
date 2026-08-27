import SwiftUI

/// The Now destination (Figma `7:632`).
///
/// The risk card, the pressure chart, the Health card row and the two meter cards under it,
/// in the design's own order.
///
/// ## What the two meters are, and are not
///
/// Neither is a forecast — that is `RiskOutlookCard`'s job, and these two answer questions the
/// model is not asked:
///
/// - **Weather Trigger Index** reports how far barometric pressure has moved in six hours —
///   the pipeline's own trivial baseline, read off rows the phone already has. A statement
///   about the weather, never about the user.
/// - **Model training progress** counts check-ins against the point where a personal model
///   would outweigh the population prior. The ⓘ opens `TrainingProgressSheet`, which is where
///   the difference between "48% of the data" and "48% accurate" gets stated in words.
struct NowScreen: View {

    @State private var model: HealthMetricsViewModel
    @State private var meters: NowMetersModel
    @State private var isExplainingProgress = false

    private let pressure: PressureCollectionController
    private let checkIns: any CheckInStore

    /// The forward half of the pressure chart. `nil` before the stores are open, which is a
    /// state this screen is never shown in.
    private let forecast: PressureForecastReader?

    /// The two-stage risk model behind `RiskOutlookCard` and the marks on the chart's forward
    /// line. `nil` before the stores are open, and on any build without the wiring.
    private let risk: WellbeingRiskEngine?

    /// Bumped by the root when a check-in is written. Passed straight through to the chart,
    /// which re-reads its markers on a change — see `PressureChartCard`.
    private let checkInRevision: Int

    /// Whether the risk card may be drawn. `false` past the end of an unpaid trial, which puts
    /// the locked stub in its place.
    ///
    /// Handed down as a plain `Bool` rather than by giving this screen the subscription
    /// controller: what it needs is one answer, and passing the controller would let a view
    /// start reaching for prices and purchases from the middle of the Now screen.
    private let isOutlookUnlocked: Bool

    /// Opens the offer. Owned by the root, which is where every sheet in the app is raised.
    private let showOffer: () -> Void

    /// Side margin the design uses for every card on this screen: 20 pt inside a 351 pt
    /// frame.
    private static let horizontalMargin: CGFloat = 20

    /// Gap between two cards: 494 − (234 + 246) in the design's own coordinates.
    private static let cardSpacing: CGFloat = 14

    init(recorder: HealthSampleRecorder,
         pressure: PressureCollectionController,
         checkIns: any CheckInStore,
         forecast: PressureForecastReader? = nil,
         risk: WellbeingRiskEngine? = nil,
         checkInRevision: Int = 0,
         isOutlookUnlocked: Bool = true,
         showOffer: @escaping () -> Void = {}) {
        _model = State(initialValue: HealthMetricsViewModel(recorder: recorder))
        _meters = State(initialValue: NowMetersModel(pressure: pressure,
                                                     checkIns: checkIns,
                                                     risk: risk))
        self.pressure = pressure
        self.checkIns = checkIns
        self.forecast = forecast
        self.risk = risk
        self.checkInRevision = checkInRevision
        self.isOutlookUnlocked = isOutlookUnlocked
        self.showOffer = showOffer
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.cardSpacing) {
                // Absent entirely when the model has nothing to say, rather than an outlined
                // box with a heading in it. Every reason it can be absent — no engine on this
                // build, a today too thinly covered to score, every window under half a
                // point — is one the user cannot act on from this screen.
                //
                // The lock is applied *inside* that test, not in front of it, and the ordering
                // is the honest one: a paywall drawn where there is no outlook to sell would
                // be charging for a card the app cannot fill yet — a cold-start install would
                // meet an offer for something it has too little history to produce, and a user
                // who paid would find the same empty space they were promised a forecast in.
                // So the stub appears only once there is genuinely something behind it.
                if meters.outlook != nil {
                    if isOutlookUnlocked, let outlook = meters.outlook {
                        RiskOutlookCard(outlook: outlook)
                    } else {
                        PremiumLockedView(feature: .riskOutlook, showOffer: showOffer)
                    }
                }

                PressureChartCard(collection: pressure,
                                  checkIns: checkIns,
                                  forecast: forecast,
                                  risk: risk,
                                  checkInRevision: checkInRevision)

                VStack(alignment: .leading, spacing: 12) {
                    HealthMetricsRow(snapshot: model.snapshot)

                    if model.showsEmptyNote {
                        Text("No Health data yet")
                            .font(Typography.cardNote)
                            .foregroundStyle(Palette.inkSubtle)
                    }
                }

                ProgressMeterCard(title: "Weather Trigger Index",
                                  value: meters.trigger?.value,
                                  tint: Palette.markerWarm,
                                  unavailableNote: meters.triggerUnavailableNote)

                ProgressMeterCard(title: "Model training progress",
                                  value: meters.training.fraction,
                                  tint: Palette.markerCool,
                                  explain: { isExplainingProgress = true })
            }
            .padding(.horizontal, Self.horizontalMargin)
            .padding(.top, Self.horizontalMargin)
            .padding(.bottom, Self.cardSpacing)
        }
        // `.task` rather than `.onAppear`: the read is async and gets cancelled with the
        // view instead of outliving it.
        .task { await model.load() }
        // Keyed, so a check-in written from the sheet moves the training bar without the
        // screen being rebuilt — a rebuild would also reset the range picked on the chart.
        .task(id: checkInRevision) { await meters.load() }
        // A barometer reading that lands while this screen is open moves the index. The chart
        // watches the same signal, for the same reason: a timer would tick whether or not
        // anything changed.
        .onChange(of: pressure.lastUpdateAt) { _, _ in
            Task { await meters.load() }
        }
        .refreshable {
            await model.reload()
            await meters.load()
        }
        .sheet(isPresented: $isExplainingProgress) {
            TrainingProgressSheet(progress: meters.training)
        }
    }
}

/// State behind the risk card and the two meter cards.
///
/// Holds no arithmetic. What the index means is `WeatherTriggerIndex.make`, what the bar
/// measures is `TrainingDataProgress`, and what the card draws is `RiskOutlook.make` — all
/// three in `Shared/`, where a test reaches them without a screen or a sensor.
///
/// The three share one pass over the log on purpose. The training bar already counted every
/// stored check-in, and the risk card needs the newest few of the same rows plus a fortnight
/// of them; reading the table twice to answer two questions about it would double the most
/// expensive read on this screen.
@MainActor
@Observable
final class NowMetersModel {

    /// What the risk card draws, or `nil` when there is no card — see `RiskOutlook.make`.
    private(set) var outlook: RiskOutlook?

    /// `nil` until the first read finishes, and again whenever the log is too thin to support
    /// a figure. `hasLoaded` separates the two for the card's note.
    private(set) var trigger: WeatherTriggerIndex?

    private(set) var training = TrainingDataProgress(checkInCount: 0)

    private(set) var hasLoaded = false

    private let pressure: PressureCollectionController
    private let checkIns: any CheckInStore

    /// The two-stage risk model. `nil` before the stores are open, and on any build without
    /// the wiring — the card is then absent and the screen renders as it did before it existed.
    private let risk: WellbeingRiskEngine?

    private let now: () -> Date

    init(pressure: PressureCollectionController,
         checkIns: any CheckInStore,
         risk: WellbeingRiskEngine? = nil,
         now: @escaping () -> Date = Date.init) {
        self.pressure = pressure
        self.checkIns = checkIns
        self.risk = risk
        self.now = now
    }

    /// Why the index card has no figure, or `nil` while it does.
    ///
    /// Three different absences, and the user can act on exactly one of them. A device with no
    /// barometer will never fill this card and has to say so instead of looking like it is
    /// still loading; a thin log fills itself as the phone gets used; and the moment before the
    /// first read returns is not an absence at all, so it stays blank.
    var triggerUnavailableNote: LocalizedStringKey? {
        guard trigger == nil, hasLoaded else { return nil }
        guard pressure.isBarometerAvailable else { return "This device has no barometer" }

        return "Not enough pressure readings in the last few hours"
    }

    func load() async {
        let instant = now()

        let samples = await pressure.samples(trailing: WeatherTriggerIndex.windowSeconds)
        trigger = WeatherTriggerIndex.make(from: samples, asOf: instant)

        // Every stored check-in, counted. `CheckInStore` reads a range and has no count of its
        // own, so this pulls the rows to count them — acceptable at this table's size (a few a
        // day against a five-year horizon) and worth replacing with a `count(in:)` on the
        // protocol before anything else needs the same figure.
        let recorded = (try? await checkIns.checkIns(in: Date.distantPast..<instant)) ?? []
        training = TrainingDataProgress(checkInCount: recorded.count)

        // No new wake source and no second computation. This and the chart's own call are
        // concurrent `.task`s of the same view, so the memo alone would not have covered them:
        // both would miss a cache that is only written at the end and both would fit. The
        // engine coalesces them onto one build (`WellbeingRiskEngine.inFlight`), and a later
        // call inside `forecastCacheSeconds` — the barometer's own 15-minute sampling floor —
        // gets the memoised answer.
        outlook = RiskOutlook.make(risk: await risk?.forecast(asOf: instant),
                                   checkIns: recorded,
                                   asOf: instant)

        hasLoaded = true
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
        case .heartRate:
            return [HealthSample(id: UUID(), start: now, end: now, value: .heartRateBPM(72))]
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
