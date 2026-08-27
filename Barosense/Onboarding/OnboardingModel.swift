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
    case premium

    var id: Int { rawValue }

    /// Whether this step draws a bar of its own.
    ///
    /// False for the two closing steps. Neither is something to get through — one is the
    /// arrival and the other is what Barosense costs — and a bar over them would invite the
    /// user to hurry past the second.
    var drawsProgressBar: Bool {
        switch self {
        case .profile, .tags, .pattern, .terms, .health: true
        case .ready, .premium: false
        }
    }

    /// Which side of the palette the step draws on.
    ///
    /// Read by `OnboardingFlow` for the surface behind the step, and by the one step that
    /// inverts, so the two cannot disagree about which that is.
    ///
    /// Deliberately **not** derived from `drawsProgressBar`, which it used to be: the two
    /// answered together only for as long as exactly one step was both barless and dark.
    /// The arrival step drops the bar and stays light; only the price screen inverts.
    var palette: OnboardingPalette {
        switch self {
        case .profile, .tags, .pattern, .terms, .health, .ready: .light
        case .premium: .dark
        }
    }

    /// How many segments the progress bar draws.
    ///
    /// The bar-drawing steps plus **one**, not plus the number of closing steps. The closing
    /// pair counts as the single arrival it reads as, which is also what keeps the last
    /// interactive step at "5 of 6" — where it has always been — instead of dropping to "5 of
    /// 7" the moment a second closing step was added behind it.
    static let progressStepCount = OnboardingStep.allCases.filter(\.drawsProgressBar).count + 1

    /// Position in the bar, or `nil` where no bar is drawn.
    var completedSteps: Int? {
        drawsProgressBar ? rawValue + 1 : nil
    }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    /// The step before this one, and `nil` on the opening step.
    var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }
}

/// What the caller of a permission switch has to do next, if anything.
///
/// The same shape the Settings screen already uses for its own switches, and for the same
/// reason: opening another app is a view's job, and deciding *whether* to is the model's.
enum PermissionTapOutcome: Equatable, Sendable {

    /// The model dealt with it — a sheet was raised, or there was nothing to raise.
    case handled

    /// Only the Health app can change this now.
    case needsHealthApp

    /// Only iOS Settings can change this now.
    case needsSystemSettings
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

    // MARK: - Permission state

    /// What Barosense can read from Health, as last observed. Drives the Apple Health switch
    /// on the permissions step.
    ///
    /// Held rather than read in `body`, because reading it is a HealthKit round trip plus one
    /// probe query per type: a view that asked for it on every redraw would run the probe on
    /// every keystroke elsewhere in the flow.
    private(set) var healthAccess: HealthAccessState = .notRequested

    /// What the barometer will do for this install. Drives the pressure switch.
    ///
    /// This is the one the step was missing. Both permissions were asked for behind a single
    /// "Connect" button that reported nothing back, so a user who declined Motion & Fitness —
    /// or who never saw the prompt because the first sheet swallowed the tap — went on to a
    /// pressure chart that would never fill, with nothing on screen having said so.
    private(set) var barometerAccess: BarometerAccessState = .notRequested

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
        case .health, .ready, .premium:
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

        // Before `advance()`, so the switches are already showing the outcome if the user
        // comes back to the step. Free either way — the flow is about to leave the screen —
        // and the alternative is a step that reappears showing the state from before the two
        // sheets it raised.
        await refreshAccessStates()

        isRequestingAccess = false
        advance()
    }

    /// Re-reads both permissions.
    ///
    /// Called when the step appears, after either request, and on every foreground activation
    /// while the step is up — that last one because the only way out of a refusal is a trip to
    /// iOS Settings, and the switch has to have changed by the time the user gets back.
    func refreshAccessStates() async {
        healthAccess = await sensorAccess.healthAccess()
        barometerAccess = sensorAccess.barometerAccess()
    }

    /// The Apple Health switch's tap.
    ///
    /// Raises the sheet if there is one left to raise, and otherwise reports that only the
    /// Health app can settle it — iOS grants one sheet per install per type, so asking again
    /// does nothing at all, and a control that silently did nothing would read as broken.
    ///
    /// Never advances the step, unlike `requestHealthAccess()`. A switch is a control the user
    /// expects to stay and look at; moving the screen out from under it would take away the
    /// one thing they tapped it to see.
    @discardableResult
    func toggleHealthAccess() async -> PermissionTapOutcome {
        guard !isRequestingAccess else { return .handled }

        guard healthAccess.canPresentSheet else {
            await refreshAccessStates()
            return healthAccess == .unavailable ? .handled : .needsHealthApp
        }

        isRequestingAccess = true
        wantsHealthAccess = true
        await sensorAccess.requestHealthAccess()
        await refreshAccessStates()
        isRequestingAccess = false

        return .handled
    }

    /// The pressure switch's tap. Same shape as the Health one, and one meaningful difference:
    /// this permission's refusal *is* observable, so a denied state sends the user to iOS
    /// Settings rather than leaving them to guess.
    @discardableResult
    func toggleBarometerAccess() async -> PermissionTapOutcome {
        guard !isRequestingAccess else { return .handled }

        switch barometerAccess {
        case .unavailable:
            // No sensor on this device. Nothing to grant and nowhere to send them.
            return .handled

        case .notRequested:
            isRequestingAccess = true
            // The request *is* a reading — starting the sensor is what raises the prompt.
            await sensorAccess.requestBarometerAccess()
            await refreshAccessStates()
            isRequestingAccess = false
            return .handled

        case .granted, .denied:
            // The prompt is granted once per install. Both of these are settled answers, and
            // iOS Settings is the only place either can be changed.
            await refreshAccessStates()
            return .needsSystemSettings
        }
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
