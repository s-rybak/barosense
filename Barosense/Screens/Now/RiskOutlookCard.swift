import SwiftUI

/// The risk card at the top of the Now screen (Figma `7:654`).
///
/// The one block the screen was designed around and shipped without, because it needs the
/// model to exist first. It now does (`Shared/Risk/`), so the card lands and the stopgap row
/// inside `PressureChartCard` goes: one forecast, drawn once.
///
/// Four rows, in the design's order — a caption carrying the lead time and the percentage, a
/// headline, the chip row, and the cold-start note when it applies. What each of them means is
/// `RiskOutlook`, in `Shared/`, where a test reaches it without a screen.
///
/// ## Departures from the design, and why
///
/// 1. **The headline is not "Помірний ризик головного болю".** Naming a body outcome is the
///    one thing this app may not do — it is an App Review blocker under Guidelines 1.4.1 /
///    5.1.1, not a matter of taste (`.claude/skills/appstore_compliance/SKILL.md`), and the
///    model has never been trained on how the user feels. It was trained on **whether an entry
///    gets made**, so that is what the headline says. The clock stretch under it is the
///    "your history suggests" line the vocabulary does allow.
/// 2. **No `→` on the headline.** The frame draws one and there is nowhere for it to go: the
///    marked stretch is already drawn on the chart directly below. An arrow that is not a
///    destination is an affordance the card cannot honour.
/// 3. **The chip row scrolls horizontally.** Not for the count — that is fixed at three a side
///    by `RiskOutlook.expectedChipCount`, and three plus three plus a divider fits the card at
///    every ordinary type size. It is for the ramp above them: the chips are `@ScaledMetric`,
///    and at the accessibility sizes six of them stop fitting on any phone. Scrolling there
///    beats clipping the last one. It sits still whenever they fit, which is the common case.
/// 4. **A legend line under the chip row.** The frame draws the chips bare and says nothing
///    about them, which will not do for the forecast ones: their colour is
///    `RiskOutlook.expectedIntensity`, the user's own trailing mean, and a dashed ring tinted
///    by it reads as this occasion's forecast intensity — a number the model has never
///    produced. The line names what the rings are and whose the figure is.
///
///    It also carries the figure as a numeral, which `Palette.intensity(_:)` requires of every
///    surface that means something by the ramp. Printing it *inside* the rings instead was the
///    first attempt and is wrong twice over: on a card with four rings it stamps one average
///    onto four separate occasions, and against `Palette.ink` the ramp runs 4.17:1 (intensity
///    10) to 7.35:1 — so at the 12 pt the chips have room for, the hot end misses WCAG AA's
///    4.5:1 exactly where the value matters most. In `Typography.cardNote` on `bodyTextOnInk`
///    the same figure sits at 6.37:1.
struct RiskOutlookCard: View {

    let outlook: RiskOutlook

    /// The app's language, which is not `Locale.current` — that one is still whatever the app
    /// launched in. See `LanguageController.locale`.
    @Environment(\.locale) private var locale

    /// Day boundaries are taken in the user's own calendar, so "not today" means what the
    /// phone means by it.
    @Environment(\.calendar) private var calendar

    /// Chip geometry scales with the type ramp: the forecast chips carry a numeral, and a
    /// fixed 30 pt circle around an accessibility-size digit is a clipped digit.
    @ScaledMetric(relativeTo: .caption) private var recordedChipSize: CGFloat = 26
    @ScaledMetric(relativeTo: .caption) private var expectedChipSize: CGFloat = 30
    @ScaledMetric(relativeTo: .caption) private var dividerHeight: CGFloat = 18

    private enum Metrics {
        static let cornerRadius: CGFloat = 20
        static let padding: CGFloat = 18
        /// Between the caption, the headline, the chip row and the note.
        static let rowSpacing: CGFloat = 12
        static let chipSpacing: CGFloat = 10
        static let expectedStroke: CGFloat = 2
        /// Roughly the eight dashes the frame draws around a 30 pt ring.
        static let expectedDash: [CGFloat] = [4, 3]
        /// `letter spacing/-0_44` on the headline.
        static let headlineTracking: CGFloat = -0.44
        /// Between the headline and the clock stretch under it.
        static let headlineSpacing: CGFloat = 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            captionRow

            headlineBlock

            if outlook.hasChips {
                VStack(alignment: .leading, spacing: Metrics.headlineSpacing) {
                    chipRow

                    // Only under the dashed rings. The solid dots are the same colours the Log
                    // sheet and the chart already spend on a check-in, so they are vocabulary
                    // the user has met; the rings are new, and one of them means something the
                    // model did not say.
                    if outlook.expectedCount > 0 {
                        chipLegend
                            .font(Typography.cardNote)
                            .foregroundStyle(Palette.bodyTextOnInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Cold start is stated, not implied by a smaller number. §4 of the ML spec: through
            // the first weeks the figure is mostly the shipped prior speaking, and a percentage
            // that does not say so reads as a measurement of this user.
            if outlook.isColdStart {
                Text("Still learning your pattern — this is a general estimate")
                    .font(Typography.cardNote)
                    .foregroundStyle(Palette.bodyTextOnInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Palette.ink)
        }
    }

    // MARK: - Caption

    private var captionRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.chipSpacing) {
            if let leadText {
                leadText
                    .font(Typography.riskCaption)
                    .foregroundStyle(Palette.bodyTextOnInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let percent = outlook.checkInPercent {
                Text(verbatim: "\(percent)%")
                    .font(Typography.riskCaption)
                    .foregroundStyle(Palette.markerWarm)
                    .monospacedDigit()
                    // The figure is a bare numeral in the frame, which on its own says nothing
                    // about what it counts. Sighted readers get that from the headline directly
                    // under it; VoiceOver reads the two as separate stops, so this one carries
                    // its own subject.
                    .accessibilityLabel(Text("Check-in likely today"))
                    .accessibilityValue(Text(verbatim: "\(percent)%"))
            }
        }
    }

    /// How long until the next marked stretch, or `nil` when the model marked nothing.
    ///
    /// "Likely", and a change rather than an event: the stretch is where the *pressure* curve
    /// is marked, and the app never counts down to something happening to the user.
    private var leadText: Text? {
        switch outlook.lead {
        case .ahead(let seconds):
            let duration = Duration.seconds(seconds)
                .formatted(.units(allowed: [.days, .hours, .minutes],
                                  width: .abbreviated,
                                  maximumUnitCount: 2)
                    .locale(locale))
            return Text("Likely change in \(duration)")
        case .underWay:
            return Text("Likely change under way")
        case nil:
            return nil
        }
    }

    // MARK: - Headline

    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: Metrics.headlineSpacing) {
            headlineText
                .font(Typography.riskHeadline)
                .tracking(Metrics.headlineTracking)
                .foregroundStyle(Palette.onInk)
                .fixedSize(horizontal: false, vertical: true)

            // Only under a headline that is not already the stretch itself.
            if outlook.checkInPercent != nil, let stretchText {
                stretchText
                    .font(Typography.cardNote)
                    .foregroundStyle(Palette.markerWarm)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The loud line.
    ///
    /// The percentage's own subject when there is a percentage, and otherwise the stretch —
    /// which by then is on a later day and dates itself. `RiskOutlook.make` guarantees one of
    /// the two exists; the last branch is there so the type checker does not have to take that
    /// on trust.
    private var headlineText: Text {
        if outlook.checkInPercent != nil { return Text("Check-in likely today") }
        if let stretchText { return stretchText }

        return Text("No stretch stands out today")
    }

    /// The next marked stretch in words, or `nil` when nothing is marked.
    ///
    /// A stretch on a later day is named with its weekday. The forecast reaches four days out,
    /// and "Usually around 14:00–18:00" printed on Monday about Wednesday is not a smaller
    /// claim than the true one — it is a different and wrong one.
    private var stretchText: Text? {
        guard let stretch = outlook.stretch else { return nil }

        let time = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        let end = stretch.upperBound.formatted(time)

        guard calendar.isDate(stretch.lowerBound, inSameDayAs: outlook.dayStart) else {
            let dayAndTime = Date.FormatStyle.dateTime
                .weekday(.abbreviated).hour().minute().locale(locale)
            return Text("Usually around \(stretch.lowerBound.formatted(dayAndTime))–\(end)")
        }
        return Text("Usually around \(stretch.lowerBound.formatted(time))–\(end)")
    }

    // MARK: - Chips

    /// The recent log and the forecast on one timeline, the divider standing for now.
    private var chipRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Metrics.chipSpacing) {
                if !outlook.recent.isEmpty {
                    recordedChips
                }

                if !outlook.recent.isEmpty, outlook.expectedCount > 0 {
                    Capsule()
                        .fill(Palette.separatorOnInk)
                        .frame(width: 1, height: dividerHeight)
                        .accessibilityHidden(true)
                }

                if outlook.expectedCount > 0 {
                    expectedChips
                }
            }
            .frame(height: expectedChipSize)
        }
        .scrollIndicators(.hidden)
        // Still whenever the chips fit, which is what keeps the common case looking like the
        // frame rather than like a scroller with nothing to scroll.
        .scrollBounceBehavior(.basedOnSize)
    }

    private var recordedChips: some View {
        HStack(spacing: Metrics.chipSpacing) {
            // Indexed rather than keyed on the value: two entries of the same intensity are two
            // separate dots and must not collapse into one.
            ForEach(Array(outlook.recent.enumerated()), id: \.offset) { _, intensity in
                Circle()
                    .fill(Palette.intensity(intensity))
                    .frame(width: recordedChipSize, height: recordedChipSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Your last check-ins, out of 10"))
        .accessibilityValue(Text(verbatim: outlook.recent
            .map { "\($0.rawValue)" }
            .joined(separator: ", ")))
    }

    private var expectedChips: some View {
        HStack(spacing: Metrics.chipSpacing) {
            ForEach(0..<outlook.expectedCount, id: \.self) { _ in
                expectedChip
            }
        }
        .accessibilityElement(children: .ignore)
        // "The next", not "every": the row is capped at `RiskOutlook.expectedChipCount`, and a
        // label promising the whole set would be the one place the cap became a false claim.
        .accessibilityLabel(Text("The next stretches the model points at"))
        // The count alone. What their colour means is the legend directly below, which
        // VoiceOver reaches as its own stop — saying it twice is not twice as clear.
        .accessibilityValue(Text(verbatim: "\(outlook.expectedCount)"))
    }

    private var expectedChip: some View {
        Circle()
            .strokeBorder(expectedTint,
                          style: StrokeStyle(lineWidth: Metrics.expectedStroke,
                                             dash: Metrics.expectedDash))
            .frame(width: expectedChipSize, height: expectedChipSize)
    }

    /// What the dashed rings are, and whose the number tinting them is.
    ///
    /// Two sentences rather than one clause: the count is the model's and the colour is the
    /// user's own fortnight, and a line that ran them together would let the second borrow the
    /// first's authority. Without a trailing mean there is no second sentence to write — the
    /// rings are then in `Palette.dashedBorderOnInk` and carry no figure at all.
    private var chipLegend: Text {
        guard let intensity = outlook.expectedIntensity else {
            return Text("Dashed rings are stretches ahead")
        }
        return Text("""
            Dashed rings are stretches ahead. Their colour is your own \
            two-week average, \(intensity.rawValue) out of 10
            """)
    }

    /// The trailing average's colour, or the design's neutral ring when there is no average to
    /// take — a fresh install, or a fortnight with nothing logged.
    private var expectedTint: Color {
        outlook.expectedIntensity.map(Palette.intensity) ?? Palette.dashedBorderOnInk
    }
}

#Preview("Marked stretch") {
    RiskOutlookCard(outlook: .previewMarked)
        .padding(20)
        .background(Palette.surface)
}

#Preview("Quiet day, cold start") {
    RiskOutlookCard(outlook: .previewQuiet)
        .padding(20)
        .background(Palette.surface)
}

#Preview("No history yet") {
    RiskOutlookCard(outlook: .previewEmptyLog)
        .padding(20)
        .background(Palette.surface)
}

#Preview("More stretches than rings") {
    RiskOutlookCard(outlook: .previewCapped)
        .padding(20)
        .background(Palette.surface)
}

extension RiskOutlook {

    /// A day the model has something to say about, over a fortnight of middling entries.
    static var previewMarked: RiskOutlook {
        .preview(risk: .previewMarked, intensities: [3, 7, 6, 5, 8])
    }

    /// A quiet day in the first weeks: a percentage, nothing marked, the note showing.
    static var previewQuiet: RiskOutlook {
        .preview(risk: .previewQuiet, intensities: [4, 2])
    }

    /// The forecast without the log — the state a fresh install with a shipped prior is in.
    static var previewEmptyLog: RiskOutlook {
        .preview(risk: .previewMarked, intensities: [])
    }

    /// Four separated stretches against three rings, which is the only state that shows the
    /// cap doing anything. The other three previews merge to one ring and would let a change
    /// to `expectedChipCount` land unseen.
    static var previewCapped: RiskOutlook {
        .preview(risk: .preview(marked: [1, 3, 5, 7], chance: 0.66, cold: false),
                 intensities: [8, 7, 9, 8])
    }

    /// One entry a day back from `now`, newest last.
    private static func preview(risk: WellbeingRiskForecast,
                                intensities: [Int],
                                asOf now: Date = .now) -> RiskOutlook {
        let checkIns = intensities.enumerated().map { offset, value in
            CheckIn(timestamp: now.addingTimeInterval(-Double(intensities.count - offset) * 24 * 3600),
                    intensity: CheckInIntensity(clamping: value))
        }

        return .make(risk: risk, checkIns: checkIns, asOf: now)
            ?? RiskOutlook(checkInPercent: nil,
                           lead: nil,
                           stretch: nil,
                           dayStart: now,
                           recent: [],
                           expectedCount: 0,
                           expectedIntensity: nil,
                           isColdStart: false)
    }
}

extension WellbeingRiskForecast {

    /// A day the model has something to say about: two adjacent windows marked.
    static var previewMarked: WellbeingRiskForecast { .preview(marked: [2, 3], chance: 0.78, cold: false) }

    /// A quiet day in the first weeks. Nothing marked, and the cold-start note showing.
    static var previewQuiet: WellbeingRiskForecast { .preview(marked: [], chance: 0.31, cold: true) }

    /// Nine two-hour windows from the current whole hour, with `marked` named.
    ///
    /// Shared by this file's previews, `PressureChartCard`'s and the rendering test, so all
    /// three look at one arrangement rather than three that drift.
    ///
    /// `chance` is the **day stage's** figure, as the model produces it; what the card prints
    /// is the strongest window's joint probability, which this derives the same way the model
    /// does.
    static func preview(marked: Set<Int>,
                        chance: Double,
                        cold: Bool,
                        asOf now: Date = .now) -> WellbeingRiskForecast {
        let width = TimeInterval(RiskWindowGeometry.windowMinutes) * 60
        let dayStart = RiskPressureGrid.alignedHour(of: now)

        let windows = (0..<9).map { index in
            ScoredRiskWindow(start: dayStart.addingTimeInterval(Double(index) * width),
                             end: dayStart.addingTimeInterval(Double(index + 1) * width),
                             dayStart: dayStart,
                             confidence: marked.contains(index) ? 0.9 : 0.2,
                             combined: chance * (marked.contains(index) ? 0.9 : 0.2),
                             forecastShare: 1,
                             isMarked: marked.contains(index))
        }

        return WellbeingRiskForecast(dayStart: dayStart,
                                     checkInProbability: windows.map(\.combined).max(),
                                     windows: windows,
                                     marked: windows.filter(\.isMarked),
                                     isDayQuiet: marked.isEmpty,
                                     mayNotify: !marked.isEmpty,
                                     isColdStart: cold,
                                     dayCoverage: 1,
                                     forecastShare: 1)
    }
}
