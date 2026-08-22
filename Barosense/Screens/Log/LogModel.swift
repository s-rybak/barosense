import SwiftUI

// The state behind the check-in sheet, split out of `LogScreen.swift` when that file passed
// the 900-line ceiling in `.claude/skills/swift_conventions/SKILL.md`. Nothing else moved
// with it: the views, their components and the previews stay where they were.

/// What went wrong on the check-in sheet.
///
/// Both cases leave the form exactly as the user left it: a check-in is a minute of someone's
/// attention and must not be thrown away because the disk was full.
enum CheckInFailure: Error {

    /// The check-in row could not be written.
    case couldNotSave

    /// A new tag could not be added to the vocabulary. The check-in itself is unaffected and
    /// still saves — it simply cannot carry a tag the store never accepted.
    case couldNotSaveTag

    /// Names the write that failed and what to do, without guessing at a cause the app cannot
    /// see. Both storage failures reach the user the same way, so the wording differs only in
    /// which write it was.
    var message: LocalizedStringKey {
        switch self {
        case .couldNotSave:
            "Your check-in could not be saved. Check that the device has free space and try again."
        case .couldNotSaveTag:
            "That tag could not be added to your list. Check that the device has free space and try again."
        }
    }
}

/// State behind the check-in sheet.
///
/// Holds no domain logic. What a check-in *means* — the 1–10 scale, the label threshold, what
/// a tag identifier is — lives in `Shared/Models/`, where a test reaches it without a screen.
@MainActor
@Observable
final class LogModel {

    /// Opens at the middle of the scale, which is what the frame draws: a slider has no
    /// unset state to show, so there is nothing to draw for "not answered yet".
    ///
    /// **This biases the label** and the bias is worth stating: a user who saves without
    /// touching the track records a 5 they did not choose, and 5 is one point below the
    /// event threshold. The honest fix is to require a deliberate touch before the action
    /// enables, which the frame's always-dark button rules out. Revisit once there is enough
    /// history to see how often 5 is recorded — an implausible spike at exactly 5 is the
    /// signal, and it is measurable from the same data.
    var intensity = CheckInIntensity(clamping: 5)

    private(set) var selectedTagIDs: Set<WellbeingTag.ID> = []

    private(set) var medications: [MedicationEntry] = []

    /// Every entry the user has recorded in the last `medicationHistoryDays` days, which is
    /// what `AddMedicationSheet` turns back into chips. Their own words only — nothing is
    /// proposed, see `MedicationHistory`.
    private(set) var medicationHistory: [MedicationEntry] = []

    /// The vocabulary this check-in may use, read from the store rather than from
    /// `WellbeingTag.seeds` — the user has been adding to and retiring from it since
    /// onboarding, and the seeds are only where it started.
    private(set) var offeredTags: [WellbeingTag] = []

    /// Every tag the store holds, archived rows included.
    ///
    /// Kept so a name typed into `AddTagSheet` can be matched against the *whole* vocabulary
    /// rather than the offered half of it. A user who turned "Dizziness" off during onboarding
    /// and types it again here means that tag, not a second one under the same word — and two
    /// rows sharing a name would split every count the History card and the model are built
    /// on, with nothing on screen to show why.
    private var knownTags: [WellbeingTag] = []

    private(set) var isSaving = false

    private(set) var failure: CheckInFailure?

    private let checkInStore: any CheckInStore
    private let tagStore: any WellbeingTagStore
    private let health: any CheckInHealthContextProviding
    private let healthReadTimeout: Duration
    private let now: @Sendable () -> Date
    private let onSaved: () -> Void

    init(checkInStore: any CheckInStore,
         tagStore: any WellbeingTagStore,
         health: any CheckInHealthContextProviding,
         healthReadTimeout: Duration = .seconds(2),
         now: @escaping @Sendable () -> Date = { Date() },
         onSaved: @escaping () -> Void) {
        self.checkInStore = checkInStore
        self.tagStore = tagStore
        self.health = health
        self.healthReadTimeout = healthReadTimeout
        self.now = now
        self.onSaved = onSaved
    }

    /// How far back the medication chips look. Long enough to cover something taken once a
    /// season, short enough that a name dropped a year ago stops being offered.
    private static let medicationHistoryDays = 90

    /// The intensity always has a value, so the only thing that closes the action is a write
    /// already in flight — which matches the frame, where the button is never dimmed.
    var canSave: Bool { !isSaving }

    func load() async {
        guard knownTags.isEmpty else { return }

        // A vocabulary that will not load costs the tag section and nothing else — the
        // intensity is what makes the check-in, so the form stays usable.
        //
        // Read whole rather than through `activeTags()`: the archived rows never reach the
        // chips, but `addTag(named:)` has to be able to see them.
        knownTags = (try? await tagStore.allTags()) ?? []
        refreshOfferedTags()

        // Same rule: a history that will not load costs the chips and nothing else. The
        // medication sheet still takes free text.
        medicationHistory = await loadMedicationHistory()
    }

    /// The last `medicationHistoryDays` days of recorded entries, flattened out of their
    /// check-ins.
    ///
    /// Read through the existing windowed query rather than a new `recentMedications` method on
    /// `CheckInStore`: 90 days is a few hundred rows read once when the sheet opens, and a
    /// fourth protocol method would be a fourth thing to keep true across the store, the
    /// in-memory double and their tests — for a list only this one screen ever shows.
    private func loadMedicationHistory() async -> [MedicationEntry] {
        let end = now()
        guard let start = Calendar.current.date(byAdding: .day,
                                                value: -Self.medicationHistoryDays,
                                                to: end) else { return [] }

        let checkIns = (try? await checkInStore.checkIns(in: start..<end)) ?? []
        return checkIns.flatMap(\.medications)
    }

    func toggleTag(_ id: WellbeingTag.ID) {
        if selectedTagIDs.contains(id) {
            selectedTagIDs.remove(id)
        } else {
            selectedTagIDs.insert(id)
        }
    }

    /// Adds a word the user typed to their vocabulary and selects it for this check-in.
    ///
    /// Fire-and-forget from the sheet, like `save()`: the sheet has already dismissed by the
    /// time the store answers, and the result lands on this form rather than on the sheet.
    func addTag(named name: String) {
        Task { await commit(tagNamed: name) }
    }

    private func commit(tagNamed rawName: String) async {
        // Trimmed and bounded in `Shared/`, not here: Edit Profile writes into the same
        // vocabulary and has to arrive at the same string for the same input, or the two
        // screens would disagree about which names are already taken.
        guard let name = WellbeingTag.storedName(from: rawName) else { return }

        failure = nil

        let tag = Self.unarchived(existingTag(named: name) ?? WellbeingTag(id: .user(UUID()),
                                                                           name: name))

        // Stored before it is offered, and this ordering is load-bearing: a check-in may only
        // carry a tag identity the vocabulary can resolve. A chip selected against a row that
        // was never written would come back on the History card as "Other", with nothing left
        // anywhere to say what the user had meant.
        do {
            try await tagStore.save(tag)
        } catch {
            failure = .couldNotSaveTag
            return
        }

        knownTags.removeAll { $0.id == tag.id }
        knownTags.append(tag)
        refreshOfferedTags()

        // Selected on the way in. The user typed it because it applies to *this* check-in, and
        // making them then tap the chip they have just created is a step with no decision in it.
        selectedTagIDs.insert(tag.id)
    }

    /// The tag the user already has under this name, archived rows included.
    ///
    /// Matched on what they *read* rather than on the stored `name`: a seeded tag keeps its
    /// base-language default until it is renamed, so on a Ukrainian build the word on the chip
    /// and the word in the row are two different strings. See `WellbeingTag.isNamed(_:)`, which
    /// is also what the same field in Edit Profile matches on — two writers into one vocabulary
    /// have to agree on what counts as a duplicate.
    ///
    /// Case-insensitive, so "втома" and "Втома" are one tag. Not whitespace- or
    /// punctuation-folded beyond the trim above: past that point the app would be deciding that
    /// two words the user wrote differently mean the same thing.
    private func existingTag(named name: String) -> WellbeingTag? {
        knownTags.first { $0.isNamed(name) }
    }

    /// The same tag, not archived. Typing the name of something they retired is the user asking
    /// for it back — the alternative is a duplicate row, or a dead end on a vocabulary screen
    /// this app does not have yet.
    private static func unarchived(_ tag: WellbeingTag) -> WellbeingTag {
        guard tag.isArchived else { return tag }

        return WellbeingTag(id: tag.id, name: tag.name, isArchived: false)
    }

    private func refreshOfferedTags() {
        offeredTags = Self.inSeedOrder(knownTags.filter { !$0.isArchived })
    }

    /// Appended rather than merged. Two entries with the same name are two entries: the user
    /// may well have taken the same thing twice, and this screen is not in a position to
    /// decide they did not.
    func add(medication: MedicationEntry) {
        medications.append(medication)
    }

    func remove(medication id: MedicationEntry.ID) {
        medications.removeAll { $0.id == id }
    }

    func save() {
        Task { await commit() }
    }

    private func commit() async {
        guard !isSaving else { return }

        isSaving = true
        failure = nil
        defer { isSaving = false }

        // Health is sampled only after the user commits. Opening and abandoning the sheet
        // therefore costs no HealthKit queries and cannot leave an unstructured read behind.
        // The deadline also makes the provider best-effort in practice, not just because its
        // API is nonthrowing: a stalled HealthKit/XPC request cannot hold the user's check-in.
        let stamp = await healthContext(asOf: now())

        // `note` is left unset: the form no longer asks for one. `CheckIn.note` stays on the
        // domain type rather than being deleted with the field — it is stored, tested, and
        // documented in `.claude/context/ml-spec.md`, and removing it would be a schema
        // change made on the strength of one screen dropping its text box.
        let checkIn = CheckIn(timestamp: now(),
                              intensity: intensity,
                              tagIDs: selectedTagIDs,
                              medications: medications,
                              health: stamp)

        do {
            try await checkInStore.save(checkIn)
        } catch {
            failure = .couldNotSave
            return
        }

        onSaved()
    }

    /// Returns the Health stamp that wins a race with the save-path deadline.
    ///
    /// The tasks are intentionally unstructured. A task group waits for a cancelled child
    /// before leaving its scope, which would let a provider that is slow to observe
    /// cancellation defeat the deadline. The stream lets the save continue immediately;
    /// both losing tasks are cancelled on exit, and the real provider propagates that
    /// cancellation through `HealthSampleRecorder.refresh` before it can query another kind
    /// or write to the training log.
    private func healthContext(asOf instant: Date) async -> CheckInHealthContext {
        let (results, continuation) = AsyncStream.makeStream(
            of: CheckInHealthContext.self,
            bufferingPolicy: .bufferingOldest(1)
        )

        let read = Task { [health] in
            continuation.yield(await health.healthContext(asOf: instant))
            continuation.finish()
        }
        let deadline = Task { [healthReadTimeout] in
            do {
                try await Task.sleep(for: healthReadTimeout)
            } catch {
                return
            }
            continuation.yield(.empty)
            continuation.finish()
        }

        defer {
            read.cancel()
            deadline.cancel()
            continuation.finish()
        }

        for await result in results {
            return result
        }
        return .empty
    }

    /// Shipped tags in the order `WellbeingTag.seeds` declares them, with anything the user
    /// added after.
    ///
    /// The store sorts by the stored base-language `name`, which in a translated build is
    /// the alphabetical order of a language the user is not reading. Seed order is the only
    /// one stable across languages — and it is the order onboarding offered these same chips
    /// in, so the two screens do not shuffle the vocabulary between them.
    ///
    /// A near-copy of `OnboardingModel.inSeedOrder`; folding the two into one helper means
    /// touching the onboarding flow, which is outside this change.
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
}
