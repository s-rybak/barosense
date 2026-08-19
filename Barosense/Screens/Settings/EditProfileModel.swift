import Foundation
import SwiftUI

/// Drives the profile editor (Figma `7:1308`).
///
/// Nothing is written until Save, including the tag edits. The screen has an explicit Save
/// action, so a change that took effect on tap would make the button a lie and leave no way
/// to back out of a mis-tap — and archiving a tag is not something the user can undo from
/// this screen.
///
/// The consequence is that the working set here can differ from the store for as long as
/// the screen is open. `originalTagIDs` is what makes the difference computable at Save
/// time instead of tracked as a running list of edits.
@MainActor
@Observable
final class EditProfileModel {

    enum Failure: Error, Equatable {
        /// The profile or the tag vocabulary could not be written. The user stays on the
        /// screen with their edits intact so Save can be tried again.
        case couldNotSave
        /// The picked photo could not be read or re-encoded. Everything else is unaffected.
        case couldNotReadPhoto
    }

    // MARK: - Fields

    var displayName = ""

    /// Text, not `Int?`, for the same reason as onboarding: parsing early would collapse
    /// "cleared the field" and "typed something that is not an age" into one state.
    var ageText = ""

    var gender: Gender?

    var episodeFrequency: EpisodeFrequency?

    var typicalEpisodeDuration: EpisodeDuration?

    private(set) var avatarImageData: Data?

    /// The vocabulary as the user is leaving it — order preserved, so a tag added in this
    /// session appears where it was added rather than jumping on the next redraw.
    private(set) var tags: [WellbeingTag] = []

    // MARK: - State

    private(set) var isLoaded = false
    private(set) var isSaving = false
    private(set) var failure: Failure?

    /// Raised while the "name your tag" prompt is up.
    var isAddingTag = false
    var newTagName = ""

    private var original: UserProfile?
    private var originalTagIDs: Set<WellbeingTag.ID> = []

    /// Avatar edits, counted, and the newest one that has finished.
    ///
    /// The re-encode runs off the main actor, so two picks can be in flight at once and the
    /// slower one can land last. A counter is what makes "newest wins" decidable: an edit
    /// carries the number it was given, and applies its result only if that is still the
    /// number to beat. Remove takes a number too, so a pick that finishes after it does not
    /// put the photo back.
    private var avatarEditGeneration = 0
    private var settledAvatarEditGeneration = 0

    private let dependencies: SettingsDependencies
    private let onSaved: () -> Void

    init(dependencies: SettingsDependencies, onSaved: @escaping () -> Void) {
        self.dependencies = dependencies
        self.onSaved = onSaved
    }

    // MARK: - Loading

    func load() async {
        guard !isLoaded else { return }

        let profile = (try? await dependencies.profileStore.profile()) ?? UserProfile()
        let stored = (try? await dependencies.tagStore.activeTags()) ?? []

        original = profile
        displayName = profile.displayName ?? ""
        ageText = profile.ageYears.map(String.init) ?? ""
        gender = profile.gender
        episodeFrequency = profile.episodeFrequency
        typicalEpisodeDuration = profile.typicalEpisodeDuration
        avatarImageData = profile.avatarImageData

        tags = WellbeingTag.inSeedOrder(stored)
        originalTagIDs = Set(stored.map(\.id))
        isLoaded = true
    }

    // MARK: - Validation

    /// The typed age, if it is a number the app will store. `nil` covers both "blank" and
    /// "not a supported age"; `isAgeValid` separates them.
    var ageYears: Int? {
        guard let value = Int(ageText.trimmingCharacters(in: .whitespaces)) else { return nil }
        return UserProfile.supportedAgeYears.contains(value) ? value : nil
    }

    var isAgeValid: Bool {
        ageText.trimmingCharacters(in: .whitespaces).isEmpty || ageYears != nil
    }

    /// The vocabulary may not be emptied here for the same reason onboarding insists on
    /// one: a check-in with nothing to tag is a check-in with no label to learn from.
    var hasTags: Bool { !tags.isEmpty }

    var canSave: Bool {
        isAgeValid && hasTags && hasChanges && !isSaving && !isEncodingAvatar
    }

    /// True while a picked photo is still being re-encoded.
    ///
    /// Save is held off behind it. `edited` reads `avatarImageData`, so a save landing
    /// mid-encode would write the profile without the photo the user just picked and leave
    /// the screen looking as though it had taken.
    var isEncodingAvatar: Bool { avatarEditGeneration != settledAvatarEditGeneration }

    /// Whether anything actually differs from what was loaded. Keeps Save dim on a screen
    /// the user only opened to look at, and makes "discard?" on the way out meaningful.
    var hasChanges: Bool {
        guard let original else { return false }
        return edited != original || Set(tags.map(\.id)) != originalTagIDs
    }

    // MARK: - Editing

    func removeTag(_ id: WellbeingTag.ID) {
        tags.removeAll { $0.id == id }
    }

    func beginAddingTag() {
        newTagName = ""
        isAddingTag = true
    }

    /// Adds the typed tag to the working set.
    ///
    /// Always a `.user` identity, never a seeded slug: seeded slugs are storage identity
    /// shipped with the app, and letting the user mint one would collide with a future
    /// release that ships the same slug. Duplicate names are ignored rather than rejected
    /// with a message — the user typed something they already have, and the useful outcome
    /// is simply that nothing changes.
    func commitNewTag() {
        // Trimmed and bounded in `Shared/`, so this field and the check-in sheet's own
        // add-tag field turn the same typing into the same stored name — including the cut
        // at `WellbeingTag.maximumNameLength`, which this one is an alert and cannot show
        // happening as the user types.
        let stored = WellbeingTag.storedName(from: newTagName)
        isAddingTag = false
        newTagName = ""

        guard let name = stored else { return }
        // Matched through `isNamed`, not on `name`: a seeded tag stores its base-language
        // default, so on a Ukrainian build typing the word shown on the chip would otherwise
        // miss the row it names and add a second tag meaning the same thing. The check-in
        // sheet's own add-tag field matches the same way — one vocabulary, one rule.
        let alreadyPresent = tags.contains { $0.isNamed(name) }
        guard !alreadyPresent else { return }

        tags.append(WellbeingTag(id: .user(UUID()), name: name))
    }

    /// Re-encodes the picked photo and hangs it on the working profile.
    ///
    /// `async` because the encode is not free — see `ProfileAvatarEncoder.encoded(_:)`, which
    /// is where the work actually leaves the main actor. Nothing about the flow changes: the
    /// caller was already inside a `Task`, waiting on the picker's `loadTransferable`.
    func setAvatar(_ pickedImageData: Data?) async {
        avatarEditGeneration += 1
        let generation = avatarEditGeneration

        guard let pickedImageData else {
            avatarImageData = nil
            settledAvatarEditGeneration = generation
            return
        }

        // The error is dropped rather than inspected for the same reason it always was:
        // unreadable and un-encodable both leave the user with one thing to do, which is
        // pick a different photo.
        let encoded = try? await ProfileAvatarEncoder.encoded(pickedImageData)

        // Something newer happened while this was encoding, and its answer is the one on
        // screen. Landing this one now would replace a photo the user has already replaced.
        guard generation == avatarEditGeneration else { return }

        if let encoded {
            avatarImageData = encoded
        } else {
            failure = .couldNotReadPhoto
        }
        settledAvatarEditGeneration = generation
    }

    func removeAvatar() {
        avatarEditGeneration += 1
        settledAvatarEditGeneration = avatarEditGeneration
        avatarImageData = nil
    }

    func dismissFailure() {
        failure = nil
    }

    // MARK: - Saving

    /// Writes the vocabulary first, then the profile.
    ///
    /// Same order as onboarding's commit, for the same reason: if the profile write is what
    /// fails, a retry re-runs the vocabulary changes, and both of them are idempotent
    /// (`archive` on an already-archived tag and `save` of an unchanged tag are no-ops).
    /// The reverse order would leave a saved profile next to a vocabulary that was never
    /// updated, with nothing on screen to say so.
    func save() async {
        guard canSave else { return }

        isSaving = true
        failure = nil
        defer { isSaving = false }

        let keptIDs = Set(tags.map(\.id))

        do {
            for id in originalTagIDs where !keptIDs.contains(id) {
                try await dependencies.tagStore.archive(id: id)
            }
            for tag in tags where !originalTagIDs.contains(tag.id) {
                try await dependencies.tagStore.save(tag)
            }
            try await dependencies.profileStore.save(edited)
        } catch {
            failure = .couldNotSave
            return
        }

        original = edited
        originalTagIDs = keptIDs
        onSaved()
    }

    /// The profile as the fields currently read.
    ///
    /// Built from `original` rather than from scratch so the fields this screen does not
    /// show — when terms were accepted, when onboarding finished — survive a save. Building
    /// a fresh `UserProfile` here would clear `onboardingCompletedAt` and drop the user
    /// back into onboarding the next time the app launched.
    private var edited: UserProfile {
        var profile = original ?? UserProfile()
        profile.displayName = trimmedDisplayName
        profile.ageYears = ageYears
        profile.gender = gender
        profile.avatarImageData = avatarImageData
        profile.episodeFrequency = episodeFrequency
        profile.typicalEpisodeDuration = typicalEpisodeDuration
        return profile
    }

    private var trimmedDisplayName: String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The initial the avatar falls back to, from the name as it is being typed rather
    /// than from what is stored — the avatar updates as the user types, which is the whole
    /// point of showing it above the field.
    var initial: String {
        guard let first = trimmedDisplayName?.first else { return "" }
        return String(first).uppercased(with: .current)
    }
}

extension WellbeingTag {

    /// Shipped tags in the order `WellbeingTag.seeds` declares, with anything the user
    /// added after them.
    ///
    /// The store sorts by the stored `name`, which is base-language text — in a translated
    /// build that is the alphabetical order of a language the user is not reading. Sorting
    /// by the localised label instead would make the layout depend on the translation. The
    /// seed order is the one the design draws and the only one stable across languages.
    static func inSeedOrder(_ tags: [WellbeingTag]) -> [WellbeingTag] {
        let position = Dictionary(
            uniqueKeysWithValues: seeds.enumerated().map { ($1.id, $0) }
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
