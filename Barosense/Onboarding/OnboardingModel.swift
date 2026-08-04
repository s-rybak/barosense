import Foundation
import SwiftUI

/// The steps of the onboarding flow, in order (Figma `7:338`).
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case profile
    case tags
    case pattern
    case terms
    case health
    case ready

    var id: Int { rawValue }

    /// How many segments the progress bar draws. The closing step is the arrival, not a
    /// step to get through, so it is counted in the total but shows no bar of its own.
    static let progressStepCount = OnboardingStep.allCases.count

    /// Position in the bar, or `nil` where no bar is drawn.
    var completedSteps: Int? {
        self == .ready ? nil : rawValue + 1
    }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }
}

/// What went wrong while writing what onboarding collected.
enum OnboardingFailure: Error {
    /// The profile or the tag vocabulary could not be written. The flow keeps the user on
    /// the closing step so they can retry rather than landing in an app that has none of
    /// their answers.
    case couldNotSave
}

/// Drives the onboarding flow: holds the in-progress answers, decides when a step may be
/// left, and writes everything once at the end.
///
/// Nothing is written until the user finishes. A profile committed step by step would
/// leave a half-filled row behind if they quit at step three, and `hasCompletedOnboarding`
/// would then be the only thing separating that from a real profile. One commit at the
/// end makes "there is a profile" and "onboarding finished" the same fact.
@MainActor
@Observable
final class OnboardingModel {

    // MARK: - Answers

    var step: OnboardingStep = .profile

    var displayName: String = ""

    /// Held as text, not as `Int?`: this is what the field is bound to, and parsing it
    /// early would make "typed nothing" and "typed something invalid" the same state.
    var ageText: String = ""

    var gender: Gender?

    /// Tags the user kept. Everything offered and not kept is archived on commit.
    var selectedTagIDs: Set<WellbeingTag.ID> = []

    var episodeFrequency: EpisodeFrequency?

    var typicalEpisodeDuration: EpisodeDuration?

    var hasAcceptedTerms = false

    private(set) var wantsHealthAccess = false

    // MARK: - Loaded state

    /// The vocabulary the tag step offers, read from the store rather than from
    /// `WellbeingTag.seeds` directly — the store is what the rest of the app reads, and
    /// a second source here could offer a tag that was never inserted.
    private(set) var offeredTags: [WellbeingTag] = []

    private(set) var isSaving = false

    private(set) var failure: OnboardingFailure?

    // MARK: - Dependencies

    private let profileStore: any UserProfileStore
    private let tagStore: any WellbeingTagStore
    private let now: @Sendable () -> Date

    /// Called once the profile has been written, so the app can leave the flow.
    private let onFinished: () -> Void

    init(profileStore: any UserProfileStore,
         tagStore: any WellbeingTagStore,
         now: @escaping @Sendable () -> Date = { Date() },
         onFinished: @escaping () -> Void) {
        self.profileStore = profileStore
        self.tagStore = tagStore
        self.now = now
        self.onFinished = onFinished
    }

    // MARK: - Loading

    /// Reads the tag vocabulary and pre-selects all of it, matching the design's opening
    /// state. Starting from "everything" rather than "nothing" means the user removes
    /// what does not apply, which is the shorter path for most people.
    func load() async {
        guard offeredTags.isEmpty else { return }

        do {
            let tags = Self.inSeedOrder(try await tagStore.activeTags())
            offeredTags = tags
            selectedTagIDs = Set(tags.map(\.id))
        } catch {
            // A vocabulary that will not load is not worth blocking onboarding over: the
            // step shows nothing to choose and `canLeaveCurrentStep` keeps the user there
            // until it does.
            offeredTags = []
            selectedTagIDs = []
        }
    }

    /// Puts the shipped tags back into the order `WellbeingTag.seeds` declares, with
    /// anything the user added after them.
    ///
    /// The store returns tags sorted by their stored `name`, which is the base-language
    /// text — so in a translated build the chips would come out in the alphabetical order
    /// of a language the user is not reading. Sorting by the localised label instead would
    /// make the layout depend on the translation. The seed order is the one the design
    /// draws and the only one that is stable across languages.
    private static func inSeedOrder(_ tags: [WellbeingTag]) -> [WellbeingTag] {
        let position = Dictionary(
            uniqueKeysWithValues: WellbeingTag.seeds.enumerated().map { ($1.id, $0) }
        )

        return tags.sorted { lhs, rhs in
            switch (position[lhs.id], position[rhs.id]) {
            case let (left?, right?): left < right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.name < rhs.name
            }
        }
    }

    // MARK: - Validation

    /// The typed age, if it is a number the app will store.
    ///
    /// `nil` covers both "left blank" and "not a supported age"; `isAgeValid` separates
    /// them, because blank is allowed and a bad number is not.
    var ageYears: Int? {
        guard let value = Int(ageText.trimmingCharacters(in: .whitespaces)) else { return nil }
        return UserProfile.supportedAgeYears.contains(value) ? value : nil
    }

    /// Blank is fine — every field on the opening step is optional. A non-empty entry
    /// that is not a supported age is not.
    var isAgeValid: Bool {
        ageText.trimmingCharacters(in: .whitespaces).isEmpty || ageYears != nil
    }

    var canLeaveCurrentStep: Bool {
        switch step {
        case .profile:
            isAgeValid
        case .tags:
            // An empty vocabulary would leave the check-in screen with nothing to offer,
            // so this is the one answer the flow insists on.
            !selectedTagIDs.isEmpty
        case .pattern:
            true
        case .terms:
            hasAcceptedTerms
        case .health, .ready:
            true
        }
    }

    // MARK: - Navigation

    func toggleTag(_ id: WellbeingTag.ID) {
        if selectedTagIDs.contains(id) {
            selectedTagIDs.remove(id)
        } else {
            selectedTagIDs.insert(id)
        }
    }

    /// Advances one step, or finishes if there is nowhere left to go.
    func advance() {
        guard canLeaveCurrentStep else { return }

        guard let next = step.next else {
            Task { await finish() }
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            step = next
        }
    }

    /// The Apple Health step's primary action.
    ///
    /// It records that the user asked, and nothing else. It deliberately does **not**
    /// call `HKHealthStore.requestAuthorization`: the app reads no HealthKit type yet and
    /// `com.apple.developer.healthkit.access` is empty, so requesting one here would
    /// breach the consumer-first rule in
    /// `.claude/skills/healthkit_permissions/SKILL.md`. The real request belongs with the
    /// first feature that reads a type; until then nothing may read this as
    /// "access granted" — iOS does not reveal read authorisation anyway.
    func requestHealthAccess() {
        wantsHealthAccess = true
        advance()
    }

    func skipHealthAccess() {
        wantsHealthAccess = false
        advance()
    }

    /// Retries the closing commit after a failure.
    func retry() {
        Task { await finish() }
    }

    // MARK: - Commit

    private func finish() async {
        guard !isSaving else { return }

        isSaving = true
        failure = nil
        defer { isSaving = false }

        let timestamp = now()
        let profile = UserProfile(
            displayName: trimmedDisplayName,
            ageYears: ageYears,
            gender: gender,
            episodeFrequency: episodeFrequency,
            typicalEpisodeDuration: typicalEpisodeDuration,
            termsAcceptedAt: hasAcceptedTerms ? timestamp : nil,
            healthAccessRequestedAt: wantsHealthAccess ? timestamp : nil,
            onboardingCompletedAt: timestamp
        )

        do {
            // Vocabulary first. If the profile write is what fails, the user retries and
            // archiving runs again — it is idempotent. The reverse order would leave a
            // finished profile next to an unpruned vocabulary.
            for tag in offeredTags where !selectedTagIDs.contains(tag.id) {
                try await tagStore.archive(id: tag.id)
            }
            try await profileStore.save(profile)
        } catch {
            failure = .couldNotSave
            return
        }

        onFinished()
    }

    private var trimmedDisplayName: String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
