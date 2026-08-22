import XCTest
@testable import Barosense

/// The documents as they are actually bundled, in every language the app ships.
///
/// These read `Bundle.main`, which inside a hosted unit test is the app bundle — so a
/// document that was added to `en.lproj` and forgotten in `uk.lproj` fails here rather than
/// on someone's phone. That is the failure this file exists for: the fallback in
/// `DocumentLibrary` is deliberately silent, because a reader is better served by an English
/// privacy policy than by a blank screen, and silence is exactly what a test has to catch.
final class ShippedDocumentTests: XCTestCase {

    private let library = DocumentLibrary()

    func testEveryDocumentIsBundledInEveryLanguage() {
        for document in ShippedDocument.allCases {
            for language in AppLanguage.allCases {
                let text = library.text(for: document, in: language)

                XCTAssertFalse(text.isEmpty,
                               "\(document.rawValue).md is missing or empty in \(language.rawValue).lproj")
                XCTAssertFalse(text.title.isEmpty,
                               "\(document.rawValue).md has no title in \(language.rawValue).lproj")
            }
        }
    }

    /// Not a translation check — it cannot be one. It catches the copy-paste case: a new
    /// `.lproj` file created from the English one and never translated, which the test above
    /// would pass.
    func testTheUkrainianDocumentsAreNotTheEnglishOnes() {
        for document in ShippedDocument.allCases {
            let english = library.text(for: document, in: .english)
            let ukrainian = library.text(for: document, in: .ukrainian)

            XCTAssertNotEqual(english.title, ukrainian.title,
                              "\(document.rawValue).md looks untranslated in uk.lproj")
        }
    }

    /// Every language must answer the same questions. A section dropped in translation is a
    /// reader who cannot find out what leaves their device.
    func testTheTranslationsHaveTheSameStructure() {
        for document in ShippedDocument.allCases {
            let english = library.text(for: document, in: .english)
            let ukrainian = library.text(for: document, in: .ukrainian)

            XCTAssertEqual(english.sections.count, ukrainian.sections.count,
                           "\(document.rawValue).md has a different section count in uk.lproj")

            for (en, uk) in zip(english.sections, ukrainian.sections) {
                XCTAssertEqual(en.items.count, uk.items.count,
                               "\(document.rawValue).md section \"\(en.title)\" differs in uk.lproj")
            }
        }
    }

    /// A token that survives to the screen is a visible defect in a legal document.
    func testNoPlaceholderTokenSurvivesToTheReader() {
        for document in ShippedDocument.allCases {
            for language in AppLanguage.allCases {
                let text = library.text(for: document, in: language)
                let everything = text.sections
                    .flatMap(\.items)
                    .flatMap { [$0.title] + $0.paragraphs.map(\.content) }
                    .joined(separator: "\n")

                XCTAssertFalse(everything.contains("{{"),
                               "\(document.rawValue).md leaves an unsubstituted token in \(language.rawValue).lproj")
            }
        }
    }

    /// Core convention #5. Health-claim vocabulary is an App Review blocker, and these are the
    /// longest user-facing strings in the app — the easiest place for one to slip in.
    ///
    /// "not medical advice" is the one allowed use of the word, and the pre-submission
    /// checklist requires it, so the assertion is about the phrase rather than the word.
    func testTheDocumentsCarryNoHealthClaimVocabulary() {
        // The stems `scripts/ci/check-copy-vocabulary.sh` scans for. A test that asserts they
        // are absent from the shipped copy is the one place they legitimately appear, which is
        // what the escape hatch on the line below is for.
        let forbidden = [
            "diagnos", "cure", "clinical", "therapy", "disease", "patient" // barosense:copy-allow
        ]

        for document in ShippedDocument.allCases {
            for language in AppLanguage.allCases {
                let text = library.text(for: document, in: language)
                let everything = text.sections
                    .flatMap(\.items)
                    .flatMap { [$0.title] + $0.paragraphs.map(\.content) }
                    .joined(separator: "\n")
                    .lowercased()

                for word in forbidden {
                    XCTAssertFalse(everything.contains(word),
                                   "\(document.rawValue).md (\(language.rawValue)) contains \"\(word)\"")
                }
            }
        }
    }

    /// The statement the pre-submission checklist requires, in the documents the user is asked
    /// to accept. English only — it is the phrase that is checked, not its translation.
    func testTheEnglishTermsCarryTheRequiredDisclaimer() {
        let text = library.text(for: .termsOfUse, in: .english)
        let everything = text.sections
            .flatMap(\.items)
            .flatMap(\.paragraphs)
            .map(\.content)
            .joined(separator: "\n")
            .lowercased()

        XCTAssertTrue(everything.contains("not medical advice"))
    }

    /// The FAQ is read by finding a question, so every entry has to be a question with an
    /// answer under it. A `###` heading with no body renders as a row that opens onto nothing.
    func testEveryFAQEntryHasATitleAndAnAnswer() {
        for language in AppLanguage.allCases {
            let text = library.text(for: .faq, in: language)

            for section in text.sections {
                XCTAssertFalse(section.title.isEmpty,
                               "faq.md (\(language.rawValue)) has an untitled section")

                for item in section.items {
                    XCTAssertTrue(item.hasTitle,
                                  "faq.md (\(language.rawValue)) has an answer with no question")
                    XCTAssertFalse(item.paragraphs.isEmpty,
                                   "faq.md (\(language.rawValue)) question \"\(item.title)\" has no answer")
                }
            }
        }
    }
}
