import SwiftUI

/// M6d · Frequently asked questions.
///
/// The same Markdown pipeline as `LegalDocumentScreen`, drawn differently: `###` headings
/// become rows that open, rather than sub-headings in a continuous read.
///
/// ## Why collapsible here and not in the legal documents
///
/// The two are read in opposite ways. Someone opening the FAQ arrives with one question and
/// needs to find it — a wall of answers makes the list of questions unscannable. Someone
/// opening the privacy policy may need to read all of it, so nothing there is hidden behind
/// a tap.
///
/// Everything starts closed. One open answer is the common case; opening the screen with all
/// of them expanded would put the reader in the middle of an answer to a question they did
/// not ask.
struct FAQScreen: View {

    let language: AppLanguage
    let back: () -> Void

    var library: DocumentLibrary = DocumentLibrary()

    @State private var text: DocumentText?
    @State private var expanded: Set<QuestionKey> = []

    /// Identifies one question across the whole document. `DocumentItem.id` counts from zero
    /// inside its own section, so on its own it would open the first question of every
    /// section at once.
    private struct QuestionKey: Hashable {
        let section: Int
        let item: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavigationBar(title: ShippedDocument.faq.screenTitle, back: back)

            ScrollView {
                VStack(alignment: .leading, spacing: DocumentMetrics.sectionSpacing) {
                    if let text, !text.isEmpty {
                        ForEach(text.sections) { section in
                            sectionView(section)
                        }
                    } else if text != nil {
                        DocumentUnavailableNotice()
                    }
                }
                .padding(.horizontal, SettingsMetrics.screenInset)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.ignoresSafeArea())
        .task(id: language) {
            text = library.text(for: .faq, in: language)
            // A question left open in one language would stay open at the same index in the
            // other, which is a different question. Closing everything is the honest reset.
            expanded = []
        }
    }

    private func sectionView(_ section: DocumentSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !section.title.isEmpty {
                DocumentSectionHeader(title: section.title)
                    .padding(.horizontal, 4)
            }

            SettingsCard {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        SettingsRowDivider()
                    }

                    QuestionRow(
                        item: item,
                        isOpen: binding(for: QuestionKey(section: section.id, item: item.id))
                    )
                }
            }
        }
    }

    private func binding(for key: QuestionKey) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(key) },
            set: { isOpen in
                if isOpen {
                    expanded.insert(key)
                } else {
                    expanded.remove(key)
                }
            }
        )
    }
}

/// One question and, when it is open, its answer.
///
/// The whole row is the control, not just the chevron: a 44 pt target that is the width of
/// the card is what someone reading one-handed will actually hit.
private struct QuestionRow: View {

    let item: DocumentItem
    @Binding var isOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { isOpen.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: item.title)
                        .font(Typography.settingsRowLabel)
                        .foregroundStyle(Palette.heading)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.placeholder)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        // Hidden from VoiceOver: the row already announces its state through
                        // `accessibilityValue`, and a second announcement of the same fact is
                        // noise.
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
                .padding(.vertical, SettingsMetrics.rowVerticalInset)
                .frame(minHeight: SettingsMetrics.rowMinHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOpen ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint(Text("Shows the answer"))

            if isOpen {
                DocumentParagraphsView(paragraphs: item.paragraphs)
                    .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
                    .padding(.bottom, SettingsMetrics.rowVerticalInset + 2)
                    // Slides out from under the question rather than fading in place, so the
                    // rows below are seen to move rather than appearing to jump.
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .clipped()
    }
}

#Preview {
    FAQScreen(language: .english, back: {})
}
