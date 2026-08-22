import SwiftUI

extension ShippedDocument {

    /// What the app calls this document in a navigation bar, a settings row and a link.
    ///
    /// UI copy, so it lives in the app target and goes through the string catalogue — unlike
    /// the document's own `#` heading, which arrives already translated from the Markdown.
    /// The two are allowed to differ: a navigation bar has one line, and "Questions and
    /// answers" does not fit next to a back chevron the way "FAQ" does.
    ///
    /// Held in one place so a row in Settings, a link in onboarding and the bar at the top of
    /// the pushed screen cannot drift into three names for one document.
    var screenTitle: LocalizedStringKey {
        switch self {
        case .faq: "FAQ"
        case .privacyPolicy: "Privacy policy"
        case .termsOfUse: "Terms of use"
        }
    }
}
