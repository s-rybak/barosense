import SwiftUI

// Every user-facing string of the subscription feature, in one file.
//
// Same rule and the same reason as `OnboardingCopy.swift` and `ReportCopy.swift`: `Shared/`
// is UI-free, and this is the copy bound by `.claude/skills/appstore_compliance/SKILL.md`.
//
// Two rules bite harder here than anywhere else in the app, and they pull in opposite
// directions from ordinary marketing writing:
//
//   1. **No health claim, on a screen whose whole job is to make the feature sound worth
//      paying for.** The sentence a paywall wants to write — naming a condition and promising
//      to tell the user when it is coming — is exactly the Guideline 1.4.1 / 5.1.1 rejection.
//      What is sold here is a read of the user's *own history*: a risk state, never an outcome
//      in their body.
//   2. **No price stated as fact.** Every figure the user is actually charged comes from
//      StoreKit, in their currency with their tax in it. What is written here is structure —
//      "per month", "billed yearly" — never a number. See `SubscriptionPlan`.

enum SubscriptionCopy {

    /// The product name. Kept out of the localisation table on purpose: it is a name, and a
    /// translated product name would not match the App Store listing the user is charged
    /// against.
    static let productName = "Barosense Premium" // barosense:copy-allow product name

    // MARK: - Paywall

    static var paywallTitle: LocalizedStringKey { "Barosense Premium" }

    /// Says what is bought without saying what will happen to the user. "Your history" is the
    /// subject of every clause, which is the allowed framing and also the true one.
    static var paywallSubtitle: LocalizedStringKey {
        "The full read of your own history — and the file you can hand to a doctor."
    }

    static var trialAction: LocalizedStringKey { "Start 7 days free" }

    static var subscribeAction: LocalizedStringKey { "Subscribe" }

    static var purchasingAction: LocalizedStringKey { "Contacting the App Store…" }

    static var restoreAction: LocalizedStringKey { "Restore purchases" }

    static var maybeLaterAction: LocalizedStringKey { "Not now" }

    static var includedHeader: LocalizedStringKey { "Premium adds" }

    static var freeHeader: LocalizedStringKey { "Free" }

    /// The three gated surfaces, in the order they appear in the app.
    static func included(_ feature: PremiumFeature) -> LocalizedStringKey {
        switch feature {
        case .riskOutlook: "Your risk outlook on the Now screen"
        case .insights: "Insights — the patterns in your own history"
        case .report: "The doctor report, as a PDF you can share"
        }
    }

    /// What an expired install keeps. Written out rather than implied, because the honest
    /// version of this paywall is the one that makes clear the app does not stop tracking —
    /// see `PremiumFeature`.
    ///
    /// A computed property rather than a `static let`, for the reason every other collection of
    /// `LocalizedStringKey` in this app is one: the type is not `Sendable`, so a stored static
    /// is a concurrency error under the project's complete strict-concurrency setting. Building
    /// four keys per read costs nothing — they are literals.
    static var freeForever: [LocalizedStringKey] {[
        "Check-ins, tags and your whole history",
        "The pressure chart, including the days ahead",
        "Sleep, heart rate and blood oxygen beside it",
        "Check-in reminders and the Apple Watch app"
    ]}

    // MARK: - Plans

    static func planName(_ plan: SubscriptionPlan) -> LocalizedStringKey {
        switch plan {
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }

    static func planPeriod(_ plan: SubscriptionPlan) -> LocalizedStringKey {
        switch plan {
        case .monthly: "per month"
        case .yearly: "per year"
        }
    }

    /// The saving badge, built from the two prices rather than written as a string. See
    /// `SubscriptionPlan.savingPercentAgainstMonthly`.
    ///
    /// A formatted `String`, not a `LocalizedStringKey`. Two reasons, and the second is the
    /// one that matters: a key ending in a literal `%` next to an interpolation is ambiguous
    /// to the catalogue extractor, and `.percent` already puts the sign and the symbol where
    /// the reader's locale puts them — which for a negative percentage is not the same place
    /// in every language this app ships.
    static func savingBadge(percent: Int, locale: Locale) -> String {
        (Double(-percent) / 100).formatted(.percent.locale(locale))
    }

    /// Shown while StoreKit has not answered. Not a price — a statement that there is not one
    /// yet — because a placeholder that looks like a figure is a figure the user will hold the
    /// app to.
    static var priceUnavailable: LocalizedStringKey { "Price unavailable" }

    /// The disclosure Apple requires next to any auto-renewing subscription: what renews, when
    /// it is charged, and how to stop it.
    static var renewalTerms: LocalizedStringKey {
        """
        Payment is charged to your Apple Account. The subscription renews automatically \
        unless you turn renewal off at least 24 hours before the period ends. Manage or \
        cancel it any time in Settings › Apple Account › Subscriptions.
        """
    }

    static var termsLink: LocalizedStringKey { "Terms of Use" }

    static var privacyLink: LocalizedStringKey { "Privacy Policy" }

    // MARK: - Status

    /// The Settings card's second line.
    static func activeUntil(_ date: String) -> LocalizedStringKey { "Active · until \(date)" }

    static func trialUntil(_ date: String) -> LocalizedStringKey { "Free trial · until \(date)" }

    /// The trial as a **noun**, for the status block that says what is currently running.
    /// Distinct from `trialAction`, which is a button label — "Start 7 days free" as a heading
    /// over a trial already in progress reads as an offer the user has not taken yet.
    static var trialStatus: LocalizedStringKey { "Free trial" }

    /// The date on its own, under a heading that has already named what is running.
    static func until(_ date: String) -> LocalizedStringKey { "until \(date)" }

    static var expired: LocalizedStringKey { "Your free trial has ended" }

    static var inactive: LocalizedStringKey { "See what Premium adds" }

    static var settingsRow: LocalizedStringKey { "Subscription" }

    // MARK: - Locked screens

    static var lockedTitle: LocalizedStringKey { "Part of Premium" }

    /// One line per gated surface, naming what is behind the lock rather than a generic
    /// "upgrade to continue". A stub that does not say what it is hiding is a stub the user
    /// cannot judge the price against.
    static func lockedBody(_ feature: PremiumFeature) -> LocalizedStringKey {
        switch feature {
        case .riskOutlook:
            "Your risk outlook reads the days ahead against your own history. It's part of Premium."
        case .insights:
            "Insights gathers the patterns building up in your check-ins. It's part of Premium."
        case .report:
            "The doctor report gathers your pressure, check-ins and entries into one PDF. It's part of Premium."
        }
    }

    static var lockedAction: LocalizedStringKey { "See Premium" }

    /// Under the locked stub. The reassurance that matters most on these three screens: the
    /// app has not stopped recording, so nothing is being lost while the subscription is off.
    static var lockedStillRecording: LocalizedStringKey {
        "Barosense keeps recording your check-ins and pressure either way."
    }

    // MARK: - Failures

    /// Named causes are deliberately absent: every StoreKit failure the user can act on
    /// resolves to "try again", and the rest are the App Store's to explain on its own sheet.
    static var purchaseFailed: LocalizedStringKey {
        "The purchase didn't go through. Nothing was charged — try again."
    }

    static var restoreFoundNothing: LocalizedStringKey {
        "No previous subscription found for this Apple Account."
    }

    /// The state a development build sits in until the products exist in App Store Connect.
    /// Written for a user, not a developer, because it is reachable in a shipped build with no
    /// network too.
    static var offersUnavailable: LocalizedStringKey {
        "The App Store isn't reachable right now. Try again in a moment."
    }
}
