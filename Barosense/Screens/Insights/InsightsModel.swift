import SwiftUI

/// State behind the Insights screen.
///
/// Reads the window once and hands the arithmetic to `Shared/`. Nothing here decides what an
/// insight *is*: `WellbeingInsights` does, where a test reaches it without a screen and without
/// a store, and `WellbeingRiskEngine` owns the forecast — this type only asks both of them.
///
/// ## Cost
///
/// **No new wake source.** One read per appearance of the tab, in the foreground, initiated by
/// the user tapping it. The read is `WellbeingInsights.analysisWindowDays` of barometer rows —
/// on the order of 10⁴ at the sampler's own 15-minute floor — plus the same window of check-ins
/// and the tag vocabulary, run concurrently because they are independent stores. The risk
/// forecast rides `WellbeingRiskEngine`'s existing cache: inside its fifteen-minute window this
/// costs nothing at all, and outside it the engine refits at most once a day whoever asks.
///
/// Deliberately not reloaded on scene activation, unlike Settings. Nothing another app can do
/// changes what this screen shows, and re-reading four months of rows on every return to the
/// foreground would be paying the whole cost again for an answer that has not moved.
@MainActor
@Observable
final class InsightsModel {

    private(set) var insights: WellbeingInsights = .empty

    /// `nil` until the engine answers, and also whenever it declines to — no model yet, or a
    /// log too thin to score any day. The outlook card is then absent rather than empty.
    private(set) var risk: WellbeingRiskForecast?

    /// The vocabulary, for drawing a tag in the reader's own language. Read once.
    private(set) var tagsByID: [WellbeingTag.ID: WellbeingTag] = [:]

    /// False until the first read finishes, so an empty screen and a screen still reading are
    /// distinguishable — they look identical and mean different things.
    private(set) var hasLoaded = false

    private let checkInStore: any CheckInStore
    private let pressureLog: any PressureSampleStore
    private let tagStore: any WellbeingTagStore
    private let engine: WellbeingRiskEngine?
    private let calendar: Calendar
    private let now: () -> Date

    init(checkInStore: any CheckInStore,
         pressureLog: any PressureSampleStore,
         tagStore: any WellbeingTagStore,
         engine: WellbeingRiskEngine?,
         calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init) {
        self.checkInStore = checkInStore
        self.pressureLog = pressureLog
        self.tagStore = tagStore
        self.engine = engine
        self.calendar = calendar
        self.now = now
    }

    /// Whether there is anything on this screen at all.
    ///
    /// A coefficient, a forecast, a tag, or a week with something in it. None of the four and
    /// the screen says so in one sentence instead of stacking four empty cards.
    ///
    /// `link` is on this list even though the link card also has a "keep checking in" state:
    /// the *absence* of a link is not a finding, but a link is. Left off, a user whose
    /// barometer had been quiet for a week — empty trace, no scoreable day, nothing tagged —
    /// was told there was nothing to show while the screen was holding a correlation over four
    /// months of their own history. `pattern` needs no entry of its own; it cannot outlive the
    /// link, because `WellbeingPatternNote.make` returns `nil` without one.
    ///
    /// This makes the list a superset of `isLinkPresentable`, which is the right way round: a
    /// card worth drawing implies a screen worth drawing.
    var hasAnything: Bool {
        insights.link != nil
            || risk?.outlook.isEmpty == false
            || !insights.tags.isEmpty
            || insights.trace.contains { !$0.isEmpty }
    }

    /// Whether the link card has a picture or a figure worth drawing.
    var isLinkPresentable: Bool {
        insights.link != nil || insights.trace.contains { !$0.isEmpty }
    }

    /// Reads the window and rebuilds everything on it.
    ///
    /// Safe to repeat. A store that will not answer reads as an empty window rather than as an
    /// error state: every reason it can fail is one the user cannot act on from this screen,
    /// and the cards already have a wording for "nothing here yet" that does not blame them.
    func load() async {
        let instant = now()
        let window = WellbeingInsights.analysisWindow(endingAt: instant)

        if tagsByID.isEmpty {
            let tags = (try? await tagStore.allTags()) ?? []
            tagsByID = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        // Three independent reads against three stores, and the barometer one is the expensive
        // one. Concurrent for the reason `ReportModel.load` runs its four that way.
        async let storedCheckIns = checkInStore.checkIns(in: window)
        async let storedSamples = pressureLog.samples(in: window)
        async let storedForecast = engine?.forecast(asOf: instant)

        let entries = (try? await storedCheckIns) ?? []
        let readings = (try? await storedSamples) ?? []

        insights = WellbeingInsights.make(checkIns: entries,
                                          samples: readings,
                                          tagsByID: tagsByID,
                                          calendar: calendar,
                                          asOf: instant)
        risk = await storedForecast
        hasLoaded = true
    }
}
