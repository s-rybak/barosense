import SwiftUI

// The History destination (Figma `M3 · Історія`).
//
// Three blocks in the design's own order: the period picker, a card counting what is in that
// period, and the month grid. Under the grid sits a row the design does not have — the link to
// "My medications", added because the medications page has to be reachable and the counts card
// already puts a medication figure on this screen with nowhere to go from it.
//
// ## How the period picker and the grid relate
//
// The picker widens the *counting* window; the grid always draws one month. Every window ends
// with the month the grid is showing (`CheckInHistory.window(for:anchoredOn:)`), so the ‹ ›
// arrows move both together and the card can never end up describing a stretch of time the
// user is not looking at.

// MARK: - Copy

// Display text for the period, in the app target rather than in `Shared/` — same rule as
// `OnboardingCopy.swift`: `Shared/` is UI-free and these four strings are app copy.
extension HistoryPeriod {
    var label: LocalizedStringKey {
        switch self {
        case .month: "Month"
        case .threeMonths: "3M"
        case .year: "Year"
        case .all: "All"
        }
    }
}

// MARK: - Screen

struct HistoryScreen: View {

    @State private var model: HistoryModel

    private static let horizontalMargin: CGFloat = 20
    private static let blockSpacing: CGFloat = 14

    init(checkInStore: any CheckInStore,
         tagStore: any WellbeingTagStore,
         calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init) {
        _model = State(initialValue: HistoryModel(checkInStore: checkInStore,
                                                  tagStore: tagStore,
                                                  calendar: calendar,
                                                  now: now))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Self.blockSpacing) {
                    Text("History")
                        .font(Typography.screenTitle)
                        .foregroundStyle(Palette.heading)
                        .accessibilityAddTraits(.isHeader)

                    SegmentedSelector(options: HistoryPeriod.allCases,
                                      selection: $model.period) { period in
                        Text(period.label)
                    }

                    HistorySummaryCard(title: model.windowTitle,
                                       checkInCount: model.summary.checkInCount,
                                       stats: model.stats)

                    HistoryCalendarCard(grid: model.grid,
                                        days: model.summary.days,
                                        calendar: model.calendar,
                                        currentMonth: model.currentMonth,
                                        move: model.move(byMonths:),
                                        select: model.show(month:of:))

                    medicationsLink
                }
                .padding(.horizontal, Self.horizontalMargin)
                .padding(.top, Self.horizontalMargin)
                .padding(.bottom, Self.blockSpacing)
            }
            .background(Palette.surface)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HistoryRoute.self) { route in
                switch route {
                case .medications(let window):
                    MedicationsScreen(checkInStore: model.checkInStore,
                                      window: window,
                                      periodTitle: model.windowTitle)
                }
            }
        }
        // Keyed on the query, so changing the period or stepping a month re-reads without the
        // screen being rebuilt — a rebuild would also reset the month the user navigated to.
        .task(id: model.query) { await model.load() }
    }

    /// The row the design does not draw. Deliberately styled as one of the app's choice rows
    /// rather than as a system list row, so it reads as part of the card stack above it.
    private var medicationsLink: some View {
        NavigationLink(value: HistoryRoute.medications(window: model.window)) {
            HStack(spacing: 10) {
                Text("My medications")
                    .font(Typography.choiceLabel)
                    .foregroundStyle(Palette.heading)

                Spacer(minLength: 8)

                Text("\(model.summary.medicationCount)")
                    .font(Typography.choiceLabel)
                    .foregroundStyle(Palette.inkSubtle)
                    .monospacedDigit()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.inkSubtle)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Palette.cardSurface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.cardBorder, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Where the History screen can push to. One case today; an enum rather than a bare value so
/// adding the next destination does not change the `navigationDestination` type.
enum HistoryRoute: Hashable {
    case medications(window: Range<Date>)
}

// MARK: - Summary card

/// One figure and what it counts.
struct HistoryStat: Identifiable {
    let id: String
    let value: Int
    let label: Text
}

/// "Травень 2026 · 28 записів" over up to three figures.
///
/// Counts, not conclusions. The card says how much the user recorded and what they tagged it
/// with; nothing on it ranks the period or compares it to another one.
private struct HistorySummaryCard: View {

    let title: Text
    let checkInCount: Int
    let stats: [HistoryStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            (title + Text(verbatim: " · ") + Text("\(checkInCount) entries"))
                .font(Typography.choiceLabelCompact)
                .foregroundStyle(Palette.bodyText)

            if stats.isEmpty {
                Text("Nothing recorded in this period")
                    .font(Typography.cardNote)
                    .foregroundStyle(Palette.inkSubtle)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(stats) { stat in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(stat.value)")
                                .font(Typography.metricValue)
                                .foregroundStyle(Palette.inkStrong)
                                .monospacedDigit()

                            stat.label
                                .font(Typography.metricLabel)
                                .foregroundStyle(Palette.inkSubtle)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Palette.cardSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: 1)
        }
    }
}

// MARK: - Model

/// What the History screen is looking at. Two values, one type, so `.task(id:)` re-reads on a
/// change to either without a second trigger.
struct HistoryQuery: Hashable {
    let period: HistoryPeriod
    let anchor: Date
}

/// State behind the History screen.
///
/// Reads two stores and holds what came back. Every decision about what the numbers *mean* —
/// which window a period covers, how a day's cell is coloured, how tags are ranked — is in
/// `CheckInHistory` in `Shared/`, where a test reaches it without a screen.
@MainActor
@Observable
final class HistoryModel {

    var period: HistoryPeriod = .month

    /// A date inside the month the grid is drawing.
    private(set) var anchor: Date

    private(set) var summary: HistorySummary = .empty

    /// Every tag, archived included — a check-in from March can carry a tag retired in April,
    /// and the counts card still has to be able to name it.
    private(set) var tagsByID: [WellbeingTag.ID: WellbeingTag] = [:]

    let calendar: Calendar
    let checkInStore: any CheckInStore

    private let tagStore: any WellbeingTagStore
    private let now: () -> Date

    /// How many tag figures the card has room for beside the medication one.
    private static let tagStatCount = 2

    init(checkInStore: any CheckInStore,
         tagStore: any WellbeingTagStore,
         calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init) {
        self.checkInStore = checkInStore
        self.tagStore = tagStore
        self.calendar = calendar
        self.now = now
        self.anchor = CheckInHistory.startOfMonth(containing: now(), calendar: calendar)
    }

    var query: HistoryQuery { HistoryQuery(period: period, anchor: anchor) }

    var window: Range<Date> {
        CheckInHistory.window(for: period, anchoredOn: anchor, calendar: calendar)
    }

    var grid: MonthGrid {
        CheckInHistory.grid(forMonthContaining: anchor, calendar: calendar)
    }

    /// Start of the month containing today, and the limit on everything that moves the grid.
    /// The future holds no check-ins, and a grid of empty cells is indistinguishable from a
    /// store that failed to open.
    ///
    /// Read from the clock on each access rather than fixed at init: the screen outlives
    /// midnight and, at the turn of a month, a stale limit would keep the new month unreachable.
    var currentMonth: Date {
        CheckInHistory.startOfMonth(containing: now(), calendar: calendar)
    }

    func move(byMonths step: Int) {
        anchor = min(CheckInHistory.month(offsetBy: step, from: anchor, calendar: calendar),
                     currentMonth)
    }

    /// Jump to a month outright — the calendar card's two wheels, and its "Now".
    ///
    /// Clamped by the same rule `move(byMonths:)` follows, in the one place that knows it, so a
    /// year picked while a later month is selected cannot land the grid in the future.
    func show(month: Int, of year: Int) {
        anchor = CheckInHistory.month(month, of: year, notAfter: now(), calendar: calendar)
    }

    /// The window in words: one month by name, a range of months, or "all time".
    var windowTitle: Text {
        guard period != .all else { return Text("All time") }

        let start = window.lowerBound
        // The window is half-open at the start of the next month, so the last instant it
        // actually covers is a second before its upper bound. Formatting the bound itself
        // would name a month the window excludes.
        let last = window.upperBound.addingTimeInterval(-1)

        guard !calendar.isDate(start, equalTo: last, toGranularity: .month) else {
            return Text(verbatim: Self.monthAndYear(start))
        }
        return Text(verbatim: "\(Self.shortMonthAndYear(start)) – \(Self.shortMonthAndYear(last))")
    }

    /// Up to two tags by use, then how much was taken — the three figures the design draws.
    var stats: [HistoryStat] {
        var result = summary.tagCounts.prefix(Self.tagStatCount).map { entry in
            HistoryStat(id: Self.statID(for: entry.id),
                        value: entry.count,
                        label: tagsByID[entry.id]?.label ?? Text("Other"))
        }

        if summary.medicationCount > 0 {
            result.append(HistoryStat(id: "medications",
                                      value: summary.medicationCount,
                                      label: Text("Doses taken")))
        }
        return result
    }

    /// Reads the tag vocabulary once, then the window on every query change.
    ///
    /// A store that will not open reads as an empty period. Every reason it can fail is one
    /// the user cannot act on from this screen, and the card already has a wording for
    /// "nothing here" that does not blame them for it.
    func load() async {
        if tagsByID.isEmpty {
            let tags = (try? await tagStore.allTags()) ?? []
            tagsByID = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        let checkIns = (try? await checkInStore.checkIns(in: window)) ?? []
        summary = CheckInHistory.summary(of: checkIns, calendar: calendar)
    }

    private static func monthAndYear(_ date: Date) -> String {
        let month = date.formatted(.dateTime.month(.wide)).localizedCapitalized
        return "\(month) \(date.formatted(.dateTime.year()))"
    }

    private static func shortMonthAndYear(_ date: Date) -> String {
        let month = date.formatted(.dateTime.month(.abbreviated)).localizedCapitalized
        return "\(month) \(date.formatted(.dateTime.year()))"
    }

    private static func statID(for id: WellbeingTag.ID) -> String {
        switch id {
        case .seeded(let slug): "seeded-\(slug)"
        case .user(let uuid): "user-\(uuid.uuidString)"
        }
    }
}

// MARK: - Preview

#Preview {
    HistoryScreen(checkInStore: InMemoryCheckInStore(PreviewHistory.checkIns),
                  tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds))
        .background(Palette.surface)
}

/// A month of check-ins so the grid, the counts and the link all render without a store.
enum PreviewHistory {

    /// One row of the preview month. A named type rather than a tuple so the four members
    /// stay addressable by name below; the positional init keeps the literal list a table.
    private struct PlannedDay {
        let day: Int
        let intensity: Int
        let tag: String
        let doses: Int

        init(_ day: Int, _ intensity: Int, _ tag: String, _ doses: Int) {
            self.day = day
            self.intensity = intensity
            self.tag = tag
            self.doses = doses
        }
    }

    static let checkIns: [CheckIn] = {
        let calendar = Calendar.current
        let start = CheckInHistory.startOfMonth(containing: .now, calendar: calendar)
        let plan: [PlannedDay] = [
            PlannedDay(1, 2, "fatigue", 0), PlannedDay(2, 3, "headache", 0),
            PlannedDay(4, 1, "mood", 0), PlannedDay(5, 6, "headache", 1),
            PlannedDay(6, 8, "headache", 1), PlannedDay(7, 10, "headache", 2),
            PlannedDay(10, 2, "fatigue", 0), PlannedDay(12, 5, "joints", 1),
            PlannedDay(14, 4, "fatigue", 0), PlannedDay(17, 7, "headache", 1),
            PlannedDay(19, 3, "fatigue", 0), PlannedDay(24, 9, "headache", 1)
        ]

        return plan.compactMap { entry in
            guard let day = calendar.date(byAdding: .day, value: entry.day - 1, to: start),
                  let timestamp = calendar.date(byAdding: .hour, value: 9, to: day)
            else { return nil }

            let medications = (0..<entry.doses).compactMap {
                MedicationEntry(name: "Ібупрофен",
                                dose: "400 мг",
                                takenAt: timestamp.addingTimeInterval(Double($0) * 3600))
            }

            return CheckIn(timestamp: timestamp,
                           intensity: CheckInIntensity(clamping: entry.intensity),
                           tagIDs: [.seeded(entry.tag)],
                           medications: medications)
        }
    }()
}
