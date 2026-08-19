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

    /// The step before this one, and `nil` on the opening step.
    var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
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

    /// True while the Apple Health step's system sheets are up. The step's action is
    /// disabled behind it, so a second tap cannot start a second pair of requests and land
    /// two `advance()` calls on the flow.
    private(set) var isRequestingAccess = false

    private(set) var failure: OnboardingFailure?

    // MARK: - Dependencies

    private let profileStore: any UserProfileStore
    private let tagStore: any WellbeingTagStore

    /// The two system sheets the Apple Health step raises. Injected rather than reached for
    /// directly, so this model stays runnable from a test that touches neither HealthKit nor
    /// CoreMotion.
    private let sensorAccess: any SensorAccessRequesting

    private let now: @Sendable () -> Date

    /// Called once the profile has been written, so the app can leave the flow.
    private let onFinished: () -> Void

    init(profileStore: any UserProfileStore,
         tagStore: any WellbeingTagStore,
         sensorAccess: any SensorAccessRequesting,
         now: @escaping @Sendable () -> Date = { Date() },
         onFinished: @escaping () -> Void) {
        self.profileStore = profileStore
        self.tagStore = tagStore
        self.sensorAccess = sensorAccess
        self.now = now
        self.onFinished = onFinished
    }

    // MARK: - Loading

    /// Reads the tag vocabulary. Nothing is selected to begin with.
    ///
    /// The step asks what best describes how the user feels, and a vocabulary that arrives
    /// already ticked answers it for them. A selected chip is filled with `ink`, so
    /// pre-selecting everything opens the step as a wall of dark pills with no unselected
    /// state beside them to read the control against — the one place in the app where a
    /// choice control does not start on its default surface. It also inverts what the step
    /// means: the user is deleting what is wrong instead of choosing what is right, and
    /// every chip they overlook is archived or kept on an answer they never gave. The
    /// check-in sheet, which offers the same vocabulary, has always started unselected.
    func load() async {
        guard offeredTags.isEmpty else { return }

        do {
            offeredTags = WellbeingTag.inSeedOrder(try await tagStore.activeTags())
            selectedTagIDs = []
        } catch {
            // A vocabulary that will not load is not worth blocking onboarding over: the
            // step shows nothing to choose and `canLeaveCurrentStep` keeps the user there
            // until it does.
            offeredTags = []
            selectedTagIDs = []
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

    /// Whether there is a step behind this one to go back to.
    ///
    /// False on the opening step, and false while the closing commit is in flight: a move off
    /// `.ready` mid-write would leave the user on an earlier step while `onFinished` fired
    /// under them and the flow was torn down.
    ///
    /// False while the Apple Health step's sheets are up, for the same shape of reason: that
    /// request advances the flow when it returns, and a step change underneath it would
    /// advance from wherever the user had got to instead.
    var canGoBack: Bool { step.previous != nil && !isSaving && !isRequestingAccess }

    /// Which way the last move went, so the step that arrives slides in from the side it is
    /// coming from. A back that pushed the new step in from the right would read as another
    /// step forward.
    private(set) var isMovingBack = false

    /// Advances one step, or finishes if there is nowhere left to go.
    func advance() {
        guard canLeaveCurrentStep else { return }

        guard let next = step.next else {
            Task { await finish() }
            return
        }
        isMovingBack = false
        withAnimation(.easeInOut(duration: 0.25)) {
            step = next
        }
    }

    /// Goes one step back, keeping every answer.
    ///
    /// Nothing is cleared and nothing is re-validated on the way: the point of the control is
    /// that an answer picked by mistake can be changed, and a step that reset itself on the way
    /// back would take the other answers on it down with the one being fixed.
    ///
    /// `canLeaveCurrentStep` deliberately does not apply. It guards what may be *committed*,
    /// and a user who cannot get past the tag step because they turned every tag off must not
    /// also be unable to back out of it.
    func goBack() {
        guard canGoBack, let previous = step.previous else { return }

        isMovingBack = true
        withAnimation(.easeInOut(duration: 0.25)) {
            step = previous
        }
    }

    /// The Apple Health step's primary action: raises both system sheets, then moves on.
    ///
    /// Apple Health first, the barometer second — the order the step lists them in.
    /// Sequential rather than concurrent because `requestHealthAccess` returns only once its
    /// sheet has been answered, and two prompts racing for the screen is how one of them
    /// gets dismissed unread.
    ///
    /// This is the only place in the flow that asks for anything. Both prompts used to be
    /// raised from `App.init` instead — a Health sheet and a Motion & Fitness alert on the
    /// first frame of a first launch, before a single screen had said what Barosense
    /// measures. `HealthIngestController.refreshLog` and `PressureCollectionController.start()`
    /// no longer raise either.
    ///
    /// Nothing branches on the outcome and neither call reports one: iOS never reveals a
    /// HealthKit read grant (`.claude/skills/healthkit_permissions/SKILL.md`), and a refused
    /// Motion prompt is a gap in the pressure history rather than something the flow could
    /// repair. `wantsHealthAccess` records that the user asked, which is all the profile
    /// stores.
    ///
    /// `async` rather than a method that starts its own `Task`: the step is the one piece of
    /// the flow whose whole behaviour is "what did it ask for, in what order", and a test
    /// cannot assert that against work a synchronous call left running behind it. The view
    /// wraps the call — see `HealthStep`.
    ///
    /// Two guards, because a second tap can arrive in two different ways. `isRequestingAccess`
    /// catches the one that interleaves — both the flag and its check run on the main actor
    /// before the first `await`, so a call cannot slip between them. The step check catches the
    /// one that arrives after the first has finished, when the flag is already back to `false`
    /// and the flow has moved on: without it a queued tap would ask a second time and, worse,
    /// call `advance()` again from a step the user is no longer on. Asking again is allowed
    /// only by coming back to the step, which is the one case where it is what the user meant.
    func requestHealthAccess() async {
        guard step == .health, !isRequestingAccess else { return }

        isRequestingAccess = true
        wantsHealthAccess = true

        await sensorAccess.requestHealthAccess()
        await sensorAccess.requestBarometerAccess()

        isRequestingAccess = false
        advance()
    }

    /// Past the step without asking for anything.
    ///
    /// Neither permission is lost by taking it. The Now screen requests Health on its first
    /// load, and the barometer is requested on the first foreground activation after the
    /// flow — both with the app on screen and the user already inside it. Skipping defers
    /// the two sheets; it does not decline them on the user's behalf.
    func skipHealthAccess() {
        guard !isRequestingAccess else { return }

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
