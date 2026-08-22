import SwiftUI

/// The privacy policy and the terms of use — one screen, two documents.
///
/// A plain scrolling read rather than the collapsible rows the FAQ uses. These are
/// documents somebody may need to read end to end, or search through with the system's
/// Find-on-page; sections hidden behind a tap defeat both.
///
/// The text itself is a Markdown resource, not a string in the catalogue: it runs to
/// thousands of words, and `Localizable.xcstrings` keys the source language's text as the
/// lookup key, which would turn every clause into a multi-paragraph JSON key. See
/// `DocumentLibrary`.
struct LegalDocumentScreen: View {

    let document: ShippedDocument
    let language: AppLanguage
    let back: () -> Void

    /// The navigation-bar title. Held separately from the document's own `#` heading, which
    /// is drawn in the body: the bar has one line to work with, and the two are allowed to
    /// differ.
    let title: LocalizedStringKey

    var library: DocumentLibrary = DocumentLibrary()

    /// Parsed once per appearance rather than on every layout pass. Parsing ~200 lines is
    /// cheap, but `body` runs whenever anything above it changes, and re-parsing there would
    /// tie the cost to scrolling.
    @State private var text: DocumentText?

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavigationBar(title: title, back: back)

            ScrollView {
                VStack(alignment: .leading, spacing: DocumentMetrics.sectionSpacing) {
                    if let text, !text.isEmpty {
                        heading(text.title)

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
        // Keyed on the language so switching it in Settings while this screen is in the
        // navigation stack re-reads the other `.lproj` rather than leaving the previous
        // language on screen.
        .task(id: language) {
            text = library.text(for: document, in: language)
        }
    }

    @ViewBuilder
    private func heading(_ value: String) -> some View {
        if !value.isEmpty {
            Text(verbatim: value)
                .font(Typography.screenHeading)
                .foregroundStyle(Palette.heading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func sectionView(_ section: DocumentSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !section.title.isEmpty {
                DocumentSectionHeader(title: section.title)
            }

            ForEach(section.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    if item.hasTitle {
                        Text(verbatim: item.title)
                            .font(Typography.cardTitle)
                            .foregroundStyle(Palette.heading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }

                    DocumentParagraphsView(paragraphs: item.paragraphs)
                }
            }
        }
    }
}

#Preview("Privacy") {
    LegalDocumentScreen(document: .privacyPolicy,
                        language: .english,
                        back: {},
                        title: "Privacy policy")
}

#Preview("Terms") {
    LegalDocumentScreen(document: .termsOfUse,
                        language: .english,
                        back: {},
                        title: "Terms of use")
}
