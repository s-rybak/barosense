import SwiftUI

/// Where the Insights screen can push to. One case today; an enum rather than a bare value so
/// adding the next destination does not change the `navigationDestination` type — the same
/// shape `HistoryRoute` uses.
enum InsightsRoute: Hashable {
    case report
}

/// M5 · Insights (Figma `7:951`).
///
/// Four blocks in the design's own order: how pressure has lined up with the user's own scale,
/// the 1–3 day outlook, what they have tagged most, and one sentence about the pattern. The
/// heading carries a quiet pill action to the report, which is where a PDF for someone else
/// gets made.
///
/// ## Every card is independently absent
///
/// Nothing here draws an empty frame under a title. Each card is asked whether it has anything
/// and left out when it does not, and a screen with none of them says so in one sentence. That
/// is the same rule `NowScreen` applies to `RiskOutlookCard`, applied four times: an
/// empty card reads as a load that failed, and a user three days into an install would see four
/// of them.
///
/// ## The report already existed
///
/// `ReportScreen` is reachable from Settings and is now reachable from here too, which is where
/// the design puts it. It is pushed rather than duplicated — one screen, two ways in — and the
/// tab bar comes off underneath it exactly as it does from Settings.
struct InsightsScreen: View {

    /// The store bundle, needed whole because `ReportScreen` takes it whole. This screen itself
    /// reads three of its members and no more — the check-in table, the barometer log and the
    /// tag vocabulary — which is why the model takes those three by protocol rather than taking
    /// this type.
    let dependencies: SettingsDependencies

    let languages: LanguageController

    /// Raised while the report is pushed, so the root takes the tab bar away — the pushed
    /// screen draws its own navigation bar and, in the design, no tab bar under it.
    @Binding var isDetailPresented: Bool

    /// See `EnvironmentValues.tabBarInset`. Read here rather than inside `body` because it has
    /// to be applied on the far side of the `NavigationStack` that drops it.
    @Environment(\.tabBarInset) private var tabBarInset

    @State private var model: InsightsModel
    @State private var path: [InsightsRoute] = []

    init(dependencies: SettingsDependencies,
         languages: LanguageController,
         risk: WellbeingRiskEngine?,
         isDetailPresented: Binding<Bool>) {
        self.dependencies = dependencies
        self.languages = languages
        _isDetailPresented = isDetailPresented
        // The calendar is handed over rather than read from the environment, as on History and
        // Settings: this model is built in `init`, before an environment exists, and it decides
        // which seven days the sparkline draws.
        _model = State(initialValue: InsightsModel(checkInStore: dependencies.checkInStore,
                                                   pressureLog: dependencies.pressureLog,
                                                   tagStore: dependencies.tagStore,
                                                   engine: risk,
                                                   calendar: languages.calendar))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: InsightsMetrics.blockSpacing) {
                    header

                    if model.hasLoaded {
                        cards
                    }
                }
                .padding(.horizontal, InsightsMetrics.screenInset)
                .padding(.top, 8)
                .padding(.bottom, InsightsMetrics.blockSpacing)
            }
            .background(Palette.surface)
            // The tab bar's inset does not survive the `NavigationStack` above — see
            // `EnvironmentValues.tabBarInset`.
            .safeAreaPadding(.bottom, tabBarInset)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: InsightsRoute.self) { route in
                destination(for: route)
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .task { await model.load() }
        .onChange(of: path) { _, newPath in
            isDetailPresented = !newPath.isEmpty
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Insights")
                .font(Typography.screenHeading)
                .foregroundStyle(Palette.heading)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            reportAction
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    /// The pill in the heading (Figma `7:967`). A quiet action rather than a button-shaped one:
    /// it leads to a document most people will never make, and giving it the weight of the
    /// screen's primary action would be pointing at the wrong thing.
    private var reportAction: some View {
        NavigationLink(value: InsightsRoute.report) {
            HStack(spacing: 2) {
                Text(ReportScreenCopy.insightsAction)
                    .font(Typography.captionEmphasis)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Palette.bodyText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.quietActionFill)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cards

    @ViewBuilder
    private var cards: some View {
        if model.hasAnything {
            if model.isLinkPresentable {
                PressureWellbeingCard(link: model.insights.link, trace: model.insights.trace)
            }

            // Absent when the model declined to score any day — no fit yet, a log too thin, or
            // simply a late evening with nothing left ahead. A card of grey tiles would be
            // inventing three days.
            if let risk = model.risk, !risk.outlook.isEmpty {
                InsightsOutlookCard(risk: risk)
            }

            if !model.insights.tags.isEmpty {
                TopTagsCard(tags: model.insights.tags,
                            checkInCount: model.insights.checkInCount,
                            tagsByID: model.tagsByID)
            }

            if let pattern = model.insights.pattern {
                PatternNoteCard(note: pattern, tagsByID: model.tagsByID)
            }
        } else {
            empty
        }
    }

    /// One sentence, not a stack of empty cards. Says what will fill the screen and stops —
    /// there is nothing here for the user to act on beyond using the app.
    private var empty: some View {
        InsightsCard {
            Text("Nothing to show yet")
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.heading)

            Text("Patterns build up as you check in and the barometer keeps a record. Come back after a few days.")
                .font(Typography.insightBody)
                .lineSpacing(5)
                .foregroundStyle(Palette.bodyText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(for route: InsightsRoute) -> some View {
        switch route {
        case .report:
            ReportScreen(dependencies: dependencies,
                         languages: languages,
                         back: { path.removeLast() })
        }
    }
}

#Preview {
    InsightsScreen(dependencies: .preview,
                   languages: LanguageController(),
                   risk: nil,
                   isDetailPresented: .constant(false))
}
