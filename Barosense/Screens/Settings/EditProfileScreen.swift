import PhotosUI
import SwiftUI

/// M6a · Edit profile (Figma `7:1308`).
///
/// The same answers onboarding collects, in the same controls, so a value means the same
/// thing in both places — the controls come from `OnboardingComponents` rather than being
/// redrawn here.
///
/// Two deliberate differences from the frame:
///
/// - The frame is cut off after the first two frequency options and shows no duration
///   block at all. Both are on the profile and both are editable here; an editor that can
///   only change half of what onboarding asked would leave the other half unreachable for
///   the life of the install.
/// - The destructive action at the foot reads "Delete my data" rather than the frame's
///   "Delete profile". There is no useful "profile only" erase — the profile is what the
///   app reads to decide onboarding is done, so removing it alone would restart the flow
///   on top of history it no longer describes. The label says what the button does.
struct EditProfileScreen: View {

    let dependencies: SettingsDependencies
    let back: () -> Void
    let onSaved: () -> Void
    let onDeleteRequested: () -> Void

    @State private var model: EditProfileModel
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var isConfirmingDiscard = false

    init(dependencies: SettingsDependencies,
         back: @escaping () -> Void,
         onSaved: @escaping () -> Void,
         onDeleteRequested: @escaping () -> Void) {
        self.dependencies = dependencies
        self.back = back
        self.onSaved = onSaved
        self.onDeleteRequested = onDeleteRequested
        _model = State(initialValue: EditProfileModel(dependencies: dependencies,
                                                      onSaved: onSaved))
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavigationBar(
                title: "Edit profile",
                back: leave,
                actionTitle: "Save",
                isActionEnabled: model.canSave,
                action: { Task { await saveAndLeave() } }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    avatarBlock
                    ProfileDetailFields(model: model)
                    trackedTags
                    frequency
                    duration
                    deleteAction
                }
                .padding(.horizontal, SettingsMetrics.screenInset)
                .padding(.vertical, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.ignoresSafeArea())
        .task { await model.load() }
        .onChange(of: pickedPhoto) { _, item in
            Task { await loadPickedPhoto(item) }
        }
        .alert("New tag", isPresented: $model.isAddingTag) {
            TextField("Tag", text: $model.newTagName)
            Button("Cancel", role: .cancel) { model.isAddingTag = false }
            Button("Add") { model.commitNewTag() }
        } message: {
            Text("What do you want to be able to note on a check-in?")
        }
        .alert("Discard changes?", isPresented: $isConfirmingDiscard) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive, action: back)
        }
        .alert("Couldn't save", isPresented: saveFailureBinding) {
            Button("OK", role: .cancel) { model.dismissFailure() }
        } message: {
            Text("Your changes are still here. Try Save again.")
        }
        .alert("Couldn't use that photo", isPresented: photoFailureBinding) {
            Button("OK", role: .cancel) { model.dismissFailure() }
        } message: {
            Text("Pick a different one.")
        }
    }

    // MARK: - Avatar

    private var avatarBlock: some View {
        VStack(spacing: 10) {
            ProfileAvatar(imageData: model.avatarImageData,
                          initial: model.initial,
                          diameter: 76)

            HStack(spacing: 16) {
                PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                    Text("Change photo")
                        .font(Typography.linkAction)
                        .foregroundStyle(Palette.link)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                }

                if model.avatarImageData != nil {
                    Button {
                        pickedPhoto = nil
                        model.removeAvatar()
                    } label: {
                        Text("Remove")
                            .font(Typography.linkAction)
                            .foregroundStyle(Palette.placeholder)
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        // `loadTransferable` hands back the file as it sits in the library; every bit of
        // downscaling and metadata stripping happens in `ProfileAvatarEncoder`, which is
        // what `setAvatar` runs.
        let data = try? await item.loadTransferable(type: Data.self)
        model.setAvatar(data)
    }

    // MARK: - Tags

    private var trackedTags: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "What you track")

            FlowLayout {
                ForEach(model.tags) { tag in
                    RemovableTagChip(label: tag.label) {
                        model.removeTag(tag.id)
                    }
                }

                AddTagChip { model.beginAddingTag() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !model.hasTags {
                Text("Keep at least one — a check-in needs something to tag.")
                    .font(Typography.fieldUnit)
                    .foregroundStyle(Palette.destructive)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Pattern

    private var frequency: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "How often")

            VStack(spacing: 8) {
                ForEach(EpisodeFrequency.allCases, id: \.self) { option in
                    ChoiceRow(title: option.label,
                              isSelected: model.episodeFrequency == option) {
                        model.episodeFrequency = model.episodeFrequency == option ? nil : option
                    }
                }
            }
        }
    }

    private var duration: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "How long it lasts")

            FlowLayout {
                ForEach(EpisodeDuration.allCases, id: \.self) { option in
                    ChoiceChip(title: option.label,
                               isSelected: model.typicalEpisodeDuration == option) {
                        model.typicalEpisodeDuration =
                            model.typicalEpisodeDuration == option ? nil : option
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Destructive

    private var deleteAction: some View {
        Button(action: onDeleteRequested) {
            Text("Delete my data")
                .font(Typography.destructiveAction)
                .foregroundStyle(Palette.destructive)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 18)
    }

    // MARK: - Leaving

    private func leave() {
        if model.hasChanges {
            isConfirmingDiscard = true
        } else {
            back()
        }
    }

    private func saveAndLeave() async {
        await model.save()
        // Stay put on failure — the alert explains, and the edits are still in the fields.
        if model.failure == nil { back() }
    }

    private var saveFailureBinding: Binding<Bool> {
        Binding(get: { model.failure == .couldNotSave },
                set: { if !$0 { model.dismissFailure() } })
    }

    private var photoFailureBinding: Binding<Bool> {
        Binding(get: { model.failure == .couldNotReadPhoto },
                set: { if !$0 { model.dismissFailure() } })
    }
}

// MARK: - Chips

/// A tag the user keeps, with the way to drop it (Figma `7:1363`).
///
/// One button, not two side by side: the ✕ is the affordance, but a 13 pt glyph is well
/// under the 44 pt target, so the whole chip removes and the mark is what says so.
struct RemovableTagChip: View {

    let label: Text
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 8) {
                label
                    .font(Typography.choiceLabelCompact)
                    .foregroundStyle(Palette.onInk)

                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.onInk.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.ink)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(Text("Removes this tag"))
    }
}

/// The dashed "add" affordance beside the tags (Figma `7:1369`).
struct AddTagChip: View {

    let add: () -> Void

    var body: some View {
        Button(action: add) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))

                Text("Add")
                    .font(Typography.choiceLabelCompact)
            }
            .foregroundStyle(Palette.placeholder)
            .padding(.horizontal, 17)
            .padding(.vertical, 13)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.controlFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Palette.dashedBorder,
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    EditProfileScreen(dependencies: .preview,
                      back: {},
                      onSaved: {},
                      onDeleteRequested: {})
}
