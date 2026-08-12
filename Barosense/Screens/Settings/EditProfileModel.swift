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

    var canSave: Bool { isAgeValid && hasTags && hasChanges && !isSaving }

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
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        isAddingTag = false
        newTagName = ""

        guard !name.isEmpty else { return }
        // Matched through `isNamed`, not on `name`: a seeded tag stores its base-language
        // default, so on a Ukrainian build typing the word shown on the chip would otherwise
        // miss the row it names and add a second tag meaning the same thing. The check-in
        // sheet's own add-tag field matches the same way — one vocabulary, one rule.
        let alreadyPresent = tags.contains { $0.isNamed(name) }
        guard !alreadyPresent else { return }

        tags.append(WellbeingTag(id: .user(UUID()), name: name))
    }

    func setAvatar(_ pickedImageData: Data?) {
        guard let pickedImageData else {
            avatarImageData = nil
            return
        }

        do {
            avatarImageData = try ProfileAvatarEncoder.encode(pickedImageData)
        } catch {
            failure = .couldNotReadPhoto
        }
    }

    func removeAvatar() {
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
