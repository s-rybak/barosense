import SwiftUI

/// Metrics shared by the two document screens, so a paragraph in the FAQ and a paragraph in
/// the privacy policy sit on the same rhythm.
enum DocumentMetrics {
    static let paragraphSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 26
    static let bulletIndent: CGFloat = 14
    static let lineSpacing: CGFloat = 4
}

/// One paragraph of a shipped document.
///
/// ## Why `AttributedString` and not `Text(LocalizedStringKey)`
///
/// SwiftUI resolves `**bold**` inside a `Text` only for a *literal* key. These strings come
/// out of a Markdown file at runtime, so that path is closed: `Text(someString)` renders the
/// asterisks verbatim. `AttributedString(markdown:)` is the runtime equivalent, and
/// `.inlineOnlyPreservingWhitespace` keeps it to inline styling — the block structure was
/// already taken apart by `DocumentText.parse`, and letting Foundation re-interpret it here
/// would fight that.
///
/// A paragraph that fails to parse falls back to its own plain text rather than vanishing.
/// The documents include a privacy policy; a silently dropped sentence is the worst
/// available outcome.
struct DocumentParagraphView: View {

    let paragraph: DocumentParagraph

    var body: some View {
        switch paragraph {
        case .text(let value):
            styled(value)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet(let value):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // A drawn dot rather than "• " inside the string: a wrapped bullet has to
                // hang under the first word, not under the marker, and a marker that is part
                // of the string cannot do that.
                Text(verbatim: "•")
                    .font(Typography.settingsRowLabel)
                    .foregroundStyle(Palette.placeholder)

                styled(value)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, DocumentMetrics.bulletIndent)
        }
    }

    private func styled(_ value: String) -> Text {
        guard let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return Text(verbatim: value)
        }
        return Text(attributed)
    }
}

/// A run of paragraphs at the document's body rhythm.
struct DocumentParagraphsView: View {

    let paragraphs: [DocumentParagraph]

    var body: some View {
        VStack(alignment: .leading, spacing: DocumentMetrics.paragraphSpacing) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                DocumentParagraphView(paragraph: paragraph)
            }
        }
        .font(Typography.settingsRowLabel)
        .foregroundStyle(Palette.bodyText)
        .lineSpacing(DocumentMetrics.lineSpacing)
        // Without this a long paragraph inside a `ScrollView` is measured at its ideal
        // single-line width and truncated instead of wrapped.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A `##` heading, drawn from a runtime string.
///
/// `SettingsSectionHeader` takes a `LocalizedStringKey` and would read this text as a
/// lookup key that misses, so it cannot be reused here — these headings are content that
/// arrives already in the reader's language, from the document itself.
struct DocumentSectionHeader: View {

    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(Typography.sectionHeader)
            .tracking(0.48)
            .textCase(.uppercase)
            .foregroundStyle(Palette.placeholder)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// What a document screen shows when its Markdown could not be read at all.
///
/// A packaging mistake is the only way to get here, and the person looking at it tapped
/// "Privacy policy" — so this says where the answer is instead of apologising.
struct DocumentUnavailableNotice: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This document could not be loaded.")
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.heading)

            Text("Please update Barosense, or write to us from Settings › Contact us.")
                .font(Typography.settingsCaption)
                .foregroundStyle(Palette.bodyText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
