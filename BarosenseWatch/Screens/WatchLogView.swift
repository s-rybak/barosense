import Observation
import SwiftUI

/// The quick check-in (Figma `W2`): a point on the 1–10 intensity scale and whatever tags
/// apply, queued straight to the phone.
///
/// A deliberately smaller form than the phone's `LogScreen`. It drops the medication list and
/// the note, because the watch's job here is the report a user makes *while it is happening*
/// — the moment the phone is in a bag and the alternative is not logging at all. Anything
/// that wants typing belongs on the phone, and the check-in can be edited there afterwards:
/// the identifier travels with it, so editing the same row is what happens.
///
/// **Nothing is stored on the watch.** The check-in is handed to a delivery queue the system
/// persists (`CheckInTransferLink`) and the phone writes it to the one store. See that
/// protocol for why the watch does not keep its own.
struct WatchLogView: View {

    @State private var model: WatchLogModel

    @Environment(\.dismiss) private var dismiss

    /// Mirrors `model.intensity` for the Digital Crown, which binds to a continuous value.
    ///
    /// The crown is the watch's precision input and the one control that makes a ten-point
    /// scale usable without aiming at a target; the buttons stay because the crown is not
    /// discoverable and is awkward with gloves.
    @State private var crown: Double

    init(tags: [WatchTag], link: any CheckInTransferLink) {
        let model = WatchLogModel(tags: tags, link: link)
        _model = State(initialValue: model)
        _crown = State(initialValue: Double(model.intensity.rawValue))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                intensityField

                stepper

                if !model.tags.isEmpty {
                    tagChips
                }

                saveAction

                if let failure = model.failure {
                    Text(failure.message)
                        .font(WatchTypography.caption)
                        .foregroundStyle(WatchPalette.markerWarm)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 2)
        }
        .background(WatchPalette.surface)
        .navigationTitle("Intensity")
        .navigationBarTitleDisplayMode(.inline)
        .focusable()
        .digitalCrownRotation(
            $crown,
            from: Double(CheckInIntensity.scale.lowerBound),
            through: Double(CheckInIntensity.scale.upperBound),
            by: 1,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crown) { _, value in
            model.intensity = CheckInIntensity(clamping: Int(value.rounded()))
        }
        .onChange(of: model.hasSaved) { _, saved in
            guard saved else { return }
            // Long enough for the confirmation to register, short enough not to be a wait.
            // One shot, user-initiated, and the screen is already lit — not a recurring wake
            // and nothing for the battery budget to account for.
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                dismiss()
            }
        }
        .overlay {
            if model.hasSaved {
                savedConfirmation
            }
        }
    }

    // MARK: - Intensity

    private var intensityField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(model.intensity.rawValue, format: .number)
                .font(WatchTypography.intensityValue)
                .foregroundStyle(WatchIntensityRamp.colour(model.intensity))
                .monospacedDigit()
                .contentTransition(.numericText())

            // The scale's top, not a unit — spelled from `CheckInIntensity` so the two
            // cannot disagree, and verbatim because a numeral is not app copy.
            Text(verbatim: "/\(CheckInIntensity.scale.upperBound)")
                .font(WatchTypography.caption)
                .foregroundStyle(WatchPalette.inkMuted)
        }
        .animation(.snappy(duration: 0.2), value: model.intensity)
        // The stepper below is the accessibility element for this value; hearing "6" and
        // then "Intensity, 6 of 10" is hearing it twice.
        .accessibilityHidden(true)
    }

    private var stepper: some View {
        HStack(spacing: 14) {
            stepButton(systemImage: "minus", enabled: model.canDecrease) {
                model.decrease()
                crown = Double(model.intensity.rawValue)
            }

            stepButton(systemImage: "plus", enabled: model.canIncrease) {
                model.increase()
                crown = Double(model.intensity.rawValue)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Intensity")
        .accessibilityValue("\(model.intensity.rawValue) of \(CheckInIntensity.scale.upperBound)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.increase()
            case .decrement: model.decrease()
            @unknown default: break
            }
            crown = Double(model.intensity.rawValue)
        }
    }

    private func stepButton(systemImage: String,
                            enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? WatchPalette.ink : WatchPalette.inkMuted)
                // 36 pt rather than the 44 pt a phone target needs: watchOS lays its own
                // system controls out at this size, and two 44 pt circles plus their gap do
                // not fit the 40 mm width beside anything else.
                .frame(width: 36, height: 36)
                .background(Circle().fill(WatchPalette.controlFill))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Tags

    private var tagChips: some View {
        WatchChipLayout(spacing: 5) {
            ForEach(model.tags) { tag in
                let isSelected = model.selectedTagIDs.contains(tag.id)

                Button {
                    model.toggle(tag.id)
                } label: {
                    Text(tag.name)
                        .font(WatchTypography.control)
                        .foregroundStyle(isSelected ? WatchPalette.ink : WatchPalette.inkMuted)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 32)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? WatchPalette.chartLine : WatchPalette.controlFill)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tag.name)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    // MARK: - Save

    private var saveAction: some View {
        Button(action: model.save) {
            Text("Save")
                .font(WatchTypography.control)
                .foregroundStyle(model.canSave ? WatchPalette.onLight : WatchPalette.inkMuted)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(
                    Capsule(style: .continuous)
                        .fill(model.canSave ? WatchPalette.ink : WatchPalette.controlFill)
                )
        }
        .buttonStyle(.plain)
        .disabled(!model.canSave)
    }

    private var savedConfirmation: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(WatchPalette.positive)

            Text("Saved")
                .font(WatchTypography.control)
                .foregroundStyle(WatchPalette.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WatchPalette.surface)
        .transition(.opacity)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Failure copy

extension WatchLogFailure {

    /// The words for the failure. Here and not beside the model in `Shared/`, because
    /// `LocalizedStringKey` is SwiftUI and `Shared/` may not import it — the same split the
    /// rest of the app makes between what a thing *is* and how it reads.
    var message: LocalizedStringKey {
        switch self {
        case .couldNotQueue: "Couldn't send this to your phone. Try again."
        }
    }
}

// MARK: - Chip layout

/// Wraps chips onto as many rows as they need.
///
/// A `Layout` and not a `LazyVGrid`, because a grid gives every cell the same width and tag
/// names are three characters or fifteen — a fixed column either truncates the long ones or
/// wastes half the screen on the short ones.
///
/// This is a near-copy of the phone target's `FlowLayout`, for the same reason `Color(hex:)`
/// is duplicated: there is no shared-UI target and `Shared/` may not import SwiftUI. The
/// follow-up is one module, not two more copies.
private struct WatchChipLayout: Layout {

    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = rows(of: subviews, within: width)

        let height = rows.reduce(into: CGFloat.zero) { total, row in
            total += row.height + (total > 0 ? spacing : 0)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var y = bounds.minY

        for row in rows(of: subviews, within: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func rows(of subviews: Subviews, within width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)

            // The first chip of a row is placed however wide it is: wrapping it to the next
            // row would leave an empty one and it would still not fit.
            if !current.indices.isEmpty, x + size.width > width {
                rows.append(current)
                current = Row()
                x = 0
            }

            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Previews

#Preview("No link") {
    NavigationStack {
        WatchLogView(tags: WatchTag.offered(from: WellbeingTag.seeds),
                     link: NoOpCheckInTransferLink())
    }
}
