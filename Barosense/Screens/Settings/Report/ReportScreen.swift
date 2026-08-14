import SwiftUI

/// M6c · Doctor report.
///
/// Not in the Figma file — the design draws neither this screen nor the document — so it is
/// assembled from the same parts as the rest of the settings flow: the settings navigation bar,
/// a card, and the app's own segmented selector.
///
/// ## Why the preview is live views and not a rendered page
///
/// Showing an image of page one would be exact, and it would also be unreadable to VoiceOver
/// and frozen at one type size. The preview is built from the same `ReportBlockView`s the PDF
/// is, so the two cannot say different things; what differs is line wrapping, because the phone
/// is narrower than A4 and the document is pinned to the standard type size while the screen
/// follows the reader's.
///
/// The log is deliberately not in the preview — it can run to several pages — and the note
/// under the card says so, so nobody shares eight pages expecting one.
struct ReportScreen: View {

    let back: () -> Void

    @State private var model: ReportModel

    init(dependencies: SettingsDependencies,
         languages: LanguageController,
         back: @escaping () -> Void) {
        self.back = back
        _model = State(initialValue: ReportModel(dependencies: dependencies,
                                                 languages: languages))
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavigationBar(title: ReportScreenCopy.title, back: back)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(ReportScreenCopy.intro)
                        .font(Typography.settingsCaption)
                        .foregroundStyle(Palette.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)

                    SettingsSectionHeader(title: ReportScreenCopy.previewHeader)
                        .padding(.horizontal, 4)

                    previewCard

                    Text(ReportScreenCopy.previewNote)
                        .font(Typography.settingsCaption)
                        .foregroundStyle(Palette.placeholder)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, SettingsMetrics.screenInset)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        // Keyed on the period so switching it re-reads the window without rebuilding the
        // screen — a rebuild would also throw away the period the user just picked.
        .task(id: model.period) { await model.load() }
        .onDisappear { model.discardFile() }
        .sheet(item: $model.share) { item in
            ReportShareSheet(url: item.url)
        }
    }

    // MARK: - Preview

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: ReportDocumentMetrics.blockSpacing) {
            switch model.phase {
            case .loading:
                placeholder { ProgressView() }

            case .failed:
                placeholder {
                    Text(ReportScreenCopy.failure)
                        .font(Typography.cardNote)
                        .foregroundStyle(Palette.bodyText)
                        .multilineTextAlignment(.center)
                }

            case .ready, .building:
                if let report = model.report {
                    ForEach(Array(model.previewBlocks.enumerated()), id: \.offset) { _, block in
                        ReportBlockView(block: block, report: report)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: 1)
        }
    }

    private func placeholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: 160)
    }

    // MARK: - Action bar

    /// The interval and the one action, pinned to the bottom.
    ///
    /// Pinned rather than left at the end of the scroll: the preview is long, and an action the
    /// user has to scroll past the whole document to reach is an action they will look for at
    /// the top instead.
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: ReportScreenCopy.periodHeader)

            SegmentedSelector(options: ReportPeriod.allCases, selection: $model.period) { period in
                Text(period.label)
            }

            buildButton
        }
        .padding(.horizontal, SettingsMetrics.screenInset)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var buildButton: some View {
        Button {
            Task { await model.build() }
        } label: {
            HStack(spacing: 8) {
                if model.phase == .building {
                    ProgressView()
                        .tint(Palette.onInk)
                }

                Text(model.phase == .building
                    ? ReportScreenCopy.building
                    : ReportScreenCopy.build)
                    .font(Typography.primaryAction)
                    .foregroundStyle(Palette.onInk)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Palette.ink)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!model.isBuildable)
        .opacity(model.isBuildable ? 1 : 0.45)
    }
}

#Preview {
    ReportScreen(dependencies: .preview,
                 languages: LanguageController(store: UserDefaultsLanguagePreferenceStore()),
                 back: {})
}
