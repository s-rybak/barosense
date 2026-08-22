import Foundation

/// The long-form documents the app ships as Markdown resources.
///
/// Raw values are the file names in each `.lproj`. Adding a case without adding the file to
/// **every** language leaves that language showing the English text — see
/// `DocumentLibrary.text(for:in:)`, which prefers a wrong language to a blank screen.
enum ShippedDocument: String, CaseIterable, Identifiable, Sendable {
    case faq
    case privacyPolicy = "privacy-policy"
    case termsOfUse = "terms-of-use"

    /// The file name doubles as identity, which is what `.sheet(item:)` needs. Safe because
    /// the raw values are already required to be unique file names.
    var id: String { rawValue }
}

/// The handful of values the documents cannot hard-code, filled in at load time.
///
/// ## Why substitution rather than writing them into the Markdown
///
/// Every one of these appears in several documents and in both languages. Written inline,
/// changing the support address means six edits and the chance that the Ukrainian privacy
/// policy keeps an address the English one has moved on from. Here it is one edit.
///
/// **`provider` and `contactEmail` are unset on purpose.** There is no registered entity or
/// support address yet, and inventing one would put a name in a legal document that nobody
/// has agreed to answer to. They render as an em dash, the same "to be decided" mark
/// `ContactScreen` uses, and filling them in is a release blocker: App Review expects a
/// reachable privacy contact.
struct DocumentPlaceholders: Hashable, Sendable {

    /// Who publishes the app — the entity a data-protection request goes to.
    var provider: String?

    /// Where support and privacy requests are sent.
    var contactEmail: String?

    /// Whose law the terms are read under, and whose courts settle a dispute. Unset for the
    /// same reason `provider` is: it follows from where the entity is registered, and that
    /// is not decided yet.
    var jurisdiction: String?

    /// The day the current wording took effect. Bump it in the same change as any edit to
    /// the document text; a policy whose date predates its own wording is worse than no
    /// date at all.
    var effectiveDate: String

    /// `MARKETING_VERSION`, so a question about a document can be tied to a build.
    var appVersion: String

    /// What an unset value renders as. Matches `ContactScreen`.
    static let unset = "—"

    static let current = DocumentPlaceholders(
        provider: nil,
        contactEmail: nil,
        jurisdiction: nil,
        effectiveDate: "2026-08-22",
        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? unset
    )

    /// `{{token}}` → value. Unknown tokens are left alone rather than blanked, so a typo in
    /// the Markdown shows up as `{{contactemail}}` on screen instead of vanishing silently.
    func substituted(into markdown: String) -> String {
        var result = markdown
        let values = [
            "provider": provider ?? Self.unset,
            "contactEmail": contactEmail ?? Self.unset,
            "jurisdiction": jurisdiction ?? Self.unset,
            "effectiveDate": effectiveDate,
            "appVersion": appVersion
        ]
        for (token, value) in values {
            result = result.replacingOccurrences(of: "{{\(token)}}", with: value)
        }
        return result
    }
}

/// Loads a shipped document in a given language and parses it.
///
/// ## Why the language is passed in rather than taken from `Locale`
///
/// Settings can pin the app to a language the device is not set to. That switch reaches
/// every `LocalizedStringKey` in the same frame, because the root view puts the chosen
/// locale into the SwiftUI environment — but it does **not** move `Bundle.main`'s idea of
/// which `.lproj` to read, which follows `AppleLanguages` and only settles on the next
/// launch. Reading the resource the ordinary way would leave someone who just switched to
/// Ukrainian looking at an English privacy policy on a fully Ukrainian screen.
///
/// So the `.lproj` is named explicitly, from the same `AppLanguage` the rest of the UI is
/// rendering in.
struct DocumentLibrary: Sendable {

    private let bundle: Bundle
    private let placeholders: DocumentPlaceholders

    init(bundle: Bundle = .main, placeholders: DocumentPlaceholders = .current) {
        self.bundle = bundle
        self.placeholders = placeholders
    }

    /// The document, in `language` when it exists there and in English when it does not.
    ///
    /// Never throws and never returns `nil`. A missing resource is a packaging mistake that
    /// must not reach the user as a crash on the screen they opened to find out what happens
    /// to their data; it degrades to the English text, and to an empty document only if that
    /// is missing too. `DocumentScreen` draws its own notice for the empty case.
    func text(for document: ShippedDocument, in language: AppLanguage) -> DocumentText {
        guard let markdown = markdown(for: document, localization: language.languageCode)
            ?? markdown(for: document, localization: AppLanguage.english.languageCode)
        else {
            return DocumentText(title: "", sections: [])
        }
        return DocumentText.parse(placeholders.substituted(into: markdown))
    }

    private func markdown(for document: ShippedDocument, localization: String) -> String? {
        guard let url = bundle.url(forResource: document.rawValue,
                                   withExtension: "md",
                                   subdirectory: nil,
                                   localization: localization) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
