import XCTest
@testable import Barosense

/// The Markdown subset the shipped documents are written in. Pure parsing — no bundle, no
/// resources, no view.
final class DocumentTextTests: XCTestCase {

    func testTheFirstLevelOneHeadingBecomesTheTitle() {
        let text = DocumentText.parse("# Privacy policy\n\n## One\n\nBody.")

        XCTAssertEqual(text.title, "Privacy policy")
    }

    /// A second `#` is a mistake in the source. Taking it would leave the screen titled by
    /// whatever came last, which is worse than ignoring it.
    func testASecondLevelOneHeadingIsIgnored() {
        let text = DocumentText.parse("# First\n\n# Second\n\n## One\n\nBody.")

        XCTAssertEqual(text.title, "First")
    }

    func testSectionsAndItemsNest() {
        let text = DocumentText.parse("""
            # Doc

            ## Getting started

            ### What is it?

            An answer.

            ### And this?

            Another answer.

            ## Data

            ### Where does it live?

            On the device.
            """)

        XCTAssertEqual(text.sections.map(\.title), ["Getting started", "Data"])
        XCTAssertEqual(text.sections[0].items.map(\.title), ["What is it?", "And this?"])
        XCTAssertEqual(text.sections[1].items.map(\.title), ["Where does it live?"])
    }

    /// Both documents open with a sentence before any heading. Dropping it would lose the
    /// summary paragraph at the top of the privacy policy.
    func testContentBeforeTheFirstSectionIsKept() {
        let text = DocumentText.parse("# Doc\n\nA lead sentence.\n\n## One\n\nBody.")

        XCTAssertEqual(text.sections.count, 2)
        XCTAssertEqual(text.sections[0].title, "")
        XCTAssertEqual(text.sections[0].items.first?.paragraphs.first?.content, "A lead sentence.")
    }

    /// The sources are hard-wrapped so they stay readable in a diff. The wrap must not reach
    /// the screen as a line break.
    func testHardWrappedLinesJoinIntoOneParagraph() {
        let text = DocumentText.parse("""
            ## One

            A sentence that was
            wrapped across
            three lines.
            """)

        XCTAssertEqual(text.sections[0].items[0].paragraphs.count, 1)
        XCTAssertEqual(text.sections[0].items[0].paragraphs[0].content,
                       "A sentence that was wrapped across three lines.")
    }

    func testABlankLineStartsANewParagraph() {
        let text = DocumentText.parse("## One\n\nFirst.\n\nSecond.")

        XCTAssertEqual(text.sections[0].items[0].paragraphs.map(\.content), ["First.", "Second."])
    }

    func testBulletsAreDistinctFromParagraphs() {
        let text = DocumentText.parse("""
            ## One

            Lead in:

            - First point
            - Second point

            And after.
            """)

        let paragraphs = text.sections[0].items[0].paragraphs
        XCTAssertEqual(paragraphs, [.text("Lead in:"),
                                    .bullet("First point"),
                                    .bullet("Second point"),
                                    .text("And after.")])
    }

    /// Bullets are hard-wrapped in the sources like every other paragraph. Without this,
    /// the tail of a wrapped list item is flushed as its own paragraph and renders outside
    /// the list — unindented, unmarked, and reading as a stray sentence.
    func testAHardWrappedBulletStaysOneBullet() {
        let text = DocumentText.parse("""
            ## One

            - A bullet that runs on
              across two lines.
            - A second bullet.

            A following paragraph.
            """)

        XCTAssertEqual(text.sections[0].items[0].paragraphs,
                       [.bullet("A bullet that runs on across two lines."),
                        .bullet("A second bullet."),
                        .text("A following paragraph.")])
    }

    /// The line after a bullet list, with no blank line between, must not be swallowed into
    /// the last bullet — a blank line is what ends one.
    func testABlankLineEndsABullet() {
        let text = DocumentText.parse("## One\n\n- A bullet.\n\nA paragraph.")

        XCTAssertEqual(text.sections[0].items[0].paragraphs,
                       [.bullet("A bullet."), .text("A paragraph.")])
    }

    /// Inline styling is Foundation's job at render time, so the markers have to survive the
    /// structural pass intact.
    func testInlineMarkersSurvive() {
        let text = DocumentText.parse("## One\n\nIt is **not** advice.")

        XCTAssertEqual(text.sections[0].items[0].paragraphs[0].content, "It is **not** advice.")
    }

    /// Half a policy is better than a crash on the screen someone opened to find out what
    /// happens to their data.
    func testMalformedInputDegradesRatherThanFailing() {
        XCTAssertTrue(DocumentText.parse("").isEmpty)
        XCTAssertTrue(DocumentText.parse("\n\n\n").isEmpty)
        XCTAssertFalse(DocumentText.parse("Just a sentence.").isEmpty)
    }

    /// Headings with nothing under them count as empty, so the screen shows its "could not be
    /// loaded" notice rather than a page of bare headings — which is what a truncated or
    /// half-written resource actually looks like.
    func testAHeadingWithNoBodyCountsAsEmpty() {
        XCTAssertTrue(DocumentText.parse("# Doc\n\n## A section").isEmpty)
        XCTAssertFalse(DocumentText.parse("# Doc\n\n## A section\n\nOne line.").isEmpty)
    }

    /// `DocumentItem.id` counts from zero inside its own section. A `ForEach` over one section
    /// still needs them distinct.
    func testItemIdentifiersAreUniqueWithinASection() {
        let text = DocumentText.parse("""
            ## One

            ### Same heading

            A.

            ### Same heading

            B.
            """)

        let ids = text.sections[0].items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

/// Substitution of the values the documents cannot hard-code.
final class DocumentPlaceholderTests: XCTestCase {

    private let placeholders = DocumentPlaceholders(provider: "Acme",
                                                    contactEmail: "hi@example.com",
                                                    jurisdiction: "Ukraine",
                                                    effectiveDate: "2026-01-01",
                                                    appVersion: "1.2.3")

    func testEveryTokenIsReplaced() {
        let result = placeholders.substituted(into: """
            {{provider}} / {{contactEmail}} / {{jurisdiction}} / {{effectiveDate}} / {{appVersion}}
            """)

        XCTAssertEqual(result, "Acme / hi@example.com / Ukraine / 2026-01-01 / 1.2.3")
    }

    /// An entity nobody has agreed to answer to must not be invented, so an unset value shows
    /// the same "to be decided" mark `ContactScreen` uses.
    func testAnUnsetValueRendersAsTheUnsetMark() {
        let blank = DocumentPlaceholders(provider: nil,
                                         contactEmail: nil,
                                         jurisdiction: nil,
                                         effectiveDate: "2026-01-01",
                                         appVersion: "1.0")

        XCTAssertEqual(blank.substituted(into: "{{provider}}"), DocumentPlaceholders.unset)
        XCTAssertEqual(blank.substituted(into: "{{contactEmail}}"), DocumentPlaceholders.unset)
        XCTAssertEqual(blank.substituted(into: "{{jurisdiction}}"), DocumentPlaceholders.unset)
    }

    /// A typo in the Markdown has to be visible on screen rather than silently blanked.
    func testAnUnknownTokenIsLeftAlone() {
        XCTAssertEqual(placeholders.substituted(into: "{{contactemail}}"), "{{contactemail}}")
    }
}
