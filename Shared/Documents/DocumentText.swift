import Foundation

/// A paragraph inside a document item.
///
/// Two cases rather than one string with a leading "• ": the bullet's indent and hanging
/// alignment are layout, and a renderer that has to sniff the first characters of a string
/// to decide how to lay it out will eventually be handed a sentence that legitimately
/// starts with a dash.
enum DocumentParagraph: Hashable, Sendable {
    case text(String)
    case bullet(String)

    /// The words without the marker, for tests and accessibility.
    var content: String {
        switch self {
        case .text(let value), .bullet(let value): value
        }
    }
}

/// One `###` block: a heading and the paragraphs under it.
///
/// In the FAQ this is a question and its answer. In a legal document it is a numbered
/// clause. `title` is empty for the paragraphs that sit directly under a `##` heading with
/// no `###` above them — a lead-in, which both kinds of document use.
struct DocumentItem: Hashable, Sendable, Identifiable {

    /// Stable within one parse, which is all a `ForEach` needs — the documents are parsed
    /// once and never mutated. Deliberately not the title: two questions could legitimately
    /// repeat a heading, and a duplicate `id` silently drops a row.
    let id: Int
    let title: String
    let paragraphs: [DocumentParagraph]

    var hasTitle: Bool { !title.isEmpty }
}

/// One `##` section with everything under it.
struct DocumentSection: Hashable, Sendable, Identifiable {
    let id: Int
    let title: String
    let items: [DocumentItem]
}

/// A parsed document: the `#` title, and the sections under it.
struct DocumentText: Hashable, Sendable {
    let title: String
    let sections: [DocumentSection]

    var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }
}

// MARK: - Parsing

extension DocumentText {

    /// Reads the small Markdown subset the shipped documents are written in.
    ///
    /// ## Why a hand-written parser and not `AttributedString(markdown:)`
    ///
    /// Foundation's Markdown support produces styled *text*. What the screens need is
    /// *structure* — the FAQ has to know where one question ends so it can collapse it, and
    /// the legal screens need section headings they can lay out differently from body copy.
    /// A styled blob cannot answer either question. Inline styling is still Foundation's
    /// job: each paragraph keeps its `**bold**` markers and the view resolves them.
    ///
    /// The subset, in full:
    ///
    /// - `# ` — the document title, at most one, first line.
    /// - `## ` — a section.
    /// - `### ` — an item inside a section.
    /// - `- ` — a bullet paragraph.
    /// - anything else non-blank — a text paragraph; consecutive lines join into one, so the
    ///   source can be hard-wrapped without the wrap reaching the screen.
    ///
    /// Content before the first `##` is kept: it lands in an untitled section, which is how
    /// a document opens with a sentence rather than a heading.
    ///
    /// The parser never throws. A malformed document degrades to fewer sections rather than
    /// to a crash or an empty screen — this text is shown to someone who tapped
    /// "Privacy policy", and half a policy is better than an error.
    static func parse(_ markdown: String) -> DocumentText {
        var title = ""
        var sections: [DocumentSection] = []

        // The section and item currently being filled. Flushed when the next heading of the
        // same or a higher level arrives, and again at the end of the input.
        var sectionTitle = ""
        var items: [DocumentItem] = []
        var itemTitle = ""
        var paragraphs: [DocumentParagraph] = []
        // Lines of the paragraph being accumulated. A paragraph ends at a blank line, a
        // heading, or the start of another bullet — but *not* at a plain line, which is a
        // continuation of the same paragraph.
        var pending: [String] = []
        // Whether those lines belong to a bullet. A hard-wrapped bullet arrives as `- …`
        // followed by indented continuation lines, and without this the continuation is
        // flushed as a paragraph of its own — leaving the tail of a list item sitting
        // outside the list, unindented and unmarked.
        var pendingIsBullet = false

        func flushParagraph() {
            guard !pending.isEmpty else { return }
            let joined = pending.joined(separator: " ")
            paragraphs.append(pendingIsBullet ? .bullet(joined) : .text(joined))
            pending = []
            pendingIsBullet = false
        }

        func flushItem() {
            flushParagraph()
            guard !itemTitle.isEmpty || !paragraphs.isEmpty else { return }
            items.append(DocumentItem(id: items.count, title: itemTitle, paragraphs: paragraphs))
            itemTitle = ""
            paragraphs = []
        }

        func flushSection() {
            flushItem()
            guard !sectionTitle.isEmpty || !items.isEmpty else { return }
            sections.append(DocumentSection(id: sections.count, title: sectionTitle, items: items))
            sectionTitle = ""
            items = []
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
            } else if let heading = line.strippingPrefix("### ") {
                flushItem()
                itemTitle = heading
            } else if let heading = line.strippingPrefix("## ") {
                flushSection()
                sectionTitle = heading
            } else if let heading = line.strippingPrefix("# ") {
                flushSection()
                // Only the first `#` wins. A second one is a mistake in the source, and
                // taking it would leave the screen titled by whatever came last.
                if title.isEmpty { title = heading }
            } else if let bullet = line.strippingPrefix("- ") {
                flushParagraph()
                pending = [bullet]
                pendingIsBullet = true
            } else {
                pending.append(line)
            }
        }

        flushSection()

        return DocumentText(title: title, sections: sections)
    }
}

private extension String {

    /// The remainder after `prefix`, or `nil` when it is not there. Named for what it
    /// returns rather than `hasPrefix` + `dropFirst`, so the marker length is written once.
    func strippingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
