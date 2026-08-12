import SwiftUI

// MARK: - Scaffold

/// Fixed metrics of the step chrome. A file-level type rather than one nested in
/// `OnboardingStepScaffold`, because a generic type cannot hold static stored properties.
private enum ScaffoldMetrics {
    static let horizontalInset: CGFloat = 24
    static let contentTopInset: CGFloat = 32
    static let contentBottomInset: CGFloat = 24
    static let actionHeight: CGFloat = 56
    static let actionRadius: CGFloat = 18
    static let skipTopInset: CGFloat = 18
}

/// The chrome every onboarding step shares: progress, scrolling content, and the primary
/// action pinned to the bottom (Figma `7:338`).
///
/// One scaffold rather than six copies, because the six steps differ only in their
/// content and their action — and because the action is the part that must not drift:
/// it is the same height, radius and position on every step.
struct OnboardingStepScaffold<Content: View>: View {

    /// How many of `stepCount` are behind the user, inclusive of the current one.
    /// `nil` hides the bar — the closing step has no progress to report.
    var completedSteps: Int?
    var stepCount: Int = OnboardingStep.progressStepCount

    /// The dark closing step inverts every surface, so the scaffold has to know which
    /// side of the palette it is drawing on.
    var palette: OnboardingPalette = .light

    let actionTitle: LocalizedStringKey
    var isActionEnabled: Bool = true
    let action: () -> Void

    /// Optional way past the step without taking its action — only the Apple Health step
    /// has one.
    var skipTitle: LocalizedStringKey?
    var skip: (() -> Void)?

    @ViewBuilder let content: () -> Content

    private typealias Metrics = ScaffoldMetrics

    var body: some View {
        VStack(spacing: 0) {
            if let completedSteps {
                OnboardingProgressBar(completedSteps: completedSteps,
                                      stepCount: stepCount,
                                      palette: palette)
                    .padding(.horizontal, Metrics.horizontalInset)
                    .padding(.top, 18)
            }

            ScrollView {
                content()
                    .padding(.horizontal, Metrics.horizontalInset)
                    .padding(.top, Metrics.contentTopInset)
                    .padding(.bottom, Metrics.contentBottomInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The design leaves the content short of the action on every step; when the
            // content outgrows the screen the bar below stays put and the content
            // scrolls under it rather than pushing it away.
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 0) {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Typography.primaryAction)
                        .foregroundStyle(palette.actionLabel)
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.actionHeight)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.actionRadius,
                                             style: .continuous)
                                .fill(palette.actionFill)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isActionEnabled)
                // Dimmed rather than hidden: a disabled action that stays visible tells
                // the user there is something still to do on this step.
                .opacity(isActionEnabled ? 1 : 0.4)

                if let skipTitle, let skip {
                    Button(action: skip) {
                        Text(skipTitle)
                            .font(Typography.tertiaryAction)
                            .foregroundStyle(Palette.placeholder)
                            .frame(maxWidth: .infinity)
                            // Padding, not a height: the visible text is short but the
                            // tap target has to clear 44 pt.
                            .padding(.vertical, 13)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, Metrics.skipTopInset - 13)
                }
            }
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.bottom, Metrics.contentBottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.ignoresSafeArea())
    }
}

/// Which side of the palette a step draws on. Only the closing step is dark.
enum OnboardingPalette {
    case light
    case dark

    var background: Color {
        switch self {
        case .light: Palette.surface
        case .dark: Palette.ink
        }
    }

    var heading: Color {
        switch self {
        case .light: Palette.heading
        case .dark: Palette.onInk
        }
    }

    var body: Color {
        switch self {
        case .light: Palette.bodyText
        case .dark: Palette.bodyTextOnInk
        }
    }

    var actionFill: Color {
        switch self {
        case .light: Palette.ink
        case .dark: Palette.onInk
        }
    }

    var actionLabel: Color {
        switch self {
        case .light: Palette.onInk
        case .dark: Palette.ink
        }
    }
}

// MARK: - Progress

/// Six equal segments, filled left to right (Figma `7:358`).
///
/// One accessibility element reporting "step N of M" — VoiceOver reading six unlabelled
/// bars would say nothing useful.
struct OnboardingProgressBar: View {

    let completedSteps: Int
    let stepCount: Int
    var palette: OnboardingPalette = .light

    private enum Metrics {
        static let height: CGFloat = 4
        static let spacing: CGFloat = 6
    }

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index < completedSteps ? filled : unfilled)
                    .frame(height: Metrics.height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(completedSteps) of \(stepCount)"))
    }

    private var filled: Color {
        palette == .light ? Palette.ink : Palette.onInk
    }

    private var unfilled: Color {
        palette == .light ? Palette.controlBorder : Palette.elevatedInk
    }
}

// MARK: - Headings

/// Heading plus its supporting line, the block that opens most steps.
struct OnboardingHeader: View {

    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var titleFont: Font = Typography.onboardingTitle
    var subtitleFont: Font = Typography.onboardingBodySmall
    var palette: OnboardingPalette = .light
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            Text(title)
                .font(titleFont)
                .foregroundStyle(palette.heading)

            if let subtitle {
                Text(subtitle)
                    .font(subtitleFont)
                    .foregroundStyle(palette.body)
                    .lineSpacing(4)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}

// MARK: - Choices

/// A pill the user toggles (Figma `7:425`). Selected fills with `ink`; unselected is a
/// white card with a hairline border.
struct ChoiceChip: View {

    private let title: Text
    private let isSelected: Bool
    private let font: Font
    private let cornerRadius: CGFloat
    private let expands: Bool
    private let action: () -> Void

    init(title: LocalizedStringKey,
         isSelected: Bool,
         font: Font = Typography.choiceLabel,
         cornerRadius: CGFloat = 20,
         expands: Bool = false,
         action: @escaping () -> Void) {
        self.init(text: Text(title),
                  isSelected: isSelected,
                  font: font,
                  cornerRadius: cornerRadius,
                  expands: expands,
                  action: action)
    }

    /// Takes a built `Text` for a label the caller has already resolved — a tag name is
    /// app copy or user input depending on the tag, and only the caller knows which.
    ///
    /// `expands` fills the width the parent offers instead of hugging the label, which is
    /// how a fixed-count row of choices is drawn (Figma `7:1349`); `cornerRadius` because
    /// those rows are a shade squarer than the wrapping chips.
    init(text: Text,
         isSelected: Bool,
         font: Font = Typography.choiceLabel,
         cornerRadius: CGFloat = 20,
         expands: Bool = false,
         action: @escaping () -> Void) {
        self.title = text
        self.isSelected = isSelected
        self.font = font
        self.cornerRadius = cornerRadius
        self.expands = expands
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            title
                .font(font)
                .foregroundStyle(isSelected ? Palette.onInk : Palette.bodyText)
                .lineLimit(expands ? 1 : nil)
                .minimumScaleFactor(expands ? 0.75 : 1)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .frame(maxWidth: expands ? .infinity : nil)
                .background(ChoiceBackground(isSelected: isSelected, cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A full-width row the user picks from a list (Figma `7:471`). Same states as
/// `ChoiceChip`, laid out as a row because the options are sentences rather than words.
struct ChoiceRow: View {

    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.choiceLabel)
                .foregroundStyle(isSelected ? Palette.onInk : Palette.heading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .frame(minHeight: 52)
                .background(ChoiceBackground(isSelected: isSelected, cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The two-state surface behind every choice control, so a chip and a row cannot drift
/// apart visually.
private struct ChoiceBackground: View {

    let isSelected: Bool
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isSelected ? Palette.ink : Palette.controlFill)
            .overlay {
                if !isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Palette.controlBorder, lineWidth: 1)
                }
            }
    }
}

/// A row that states a fact rather than offering a choice — a coloured marker and a line
/// of text (Figma `7:572`, `7:612`).
struct MarkerRow: View {

    let text: LocalizedStringKey
    let marker: Color
    var markerSize: CGFloat = 8
    var palette: OnboardingPalette = .light

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: markerSize / 2, style: .continuous)
                .fill(marker)
                .frame(width: markerSize, height: markerSize)

            Text(text)
                .font(Typography.choiceLabelCompact)
                .foregroundStyle(palette == .light ? Palette.heading : Palette.onInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, palette == .light ? 17 : 16)
        .padding(.vertical, palette == .light ? 15 : 16)
        .background {
            let radius: CGFloat = palette == .light ? 14 : 16
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(palette == .light ? Palette.controlFill : Palette.elevatedInk)
                .overlay {
                    if palette == .light {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Palette.controlBorder, lineWidth: 1)
                    }
                }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Fields

/// The bordered 56 pt container every text input on the opening step sits in
/// (Figma `7:372`).
struct FieldSurface<Content: View>: View {

    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 18)
            .frame(minHeight: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Palette.controlFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Palette.controlBorder, lineWidth: 1)
                    }
            }
    }
}

// MARK: - Layout

/// Lays subviews out in a row and wraps to the next line when the next one will not fit.
///
/// The chip groups in the design are drawn at fixed positions, which only holds for the
/// exact strings and the exact width the designer used. Wrapping instead keeps them
/// intact in another language and at a larger Dynamic Type size — the two things that
/// would otherwise push a chip off the edge.
struct FlowLayout: Layout {

    var horizontalSpacing: CGFloat = 10
    var verticalSpacing: CGFloat = 10
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(subviews: subviews, maxWidth: maxWidth)

        let height = rows.reduce(into: CGFloat.zero) { $0 += $1.height }
            + verticalSpacing * CGFloat(max(0, rows.count - 1))

        return CGSize(width: proposal.width ?? (rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout Void) {
        var y = bounds.minY

        for row in rows(subviews: subviews, maxWidth: bounds.width) {
            var x = switch alignment {
            case .center: bounds.minX + (bounds.width - row.width) / 2
            case .trailing: bounds.maxX - row.width
            default: bounds.minX
            }

            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthWithSpacing = current.indices.isEmpty
                ? size.width
                : current.width + horizontalSpacing + size.width

            // A subview wider than the whole line still gets its own line rather than
            // being dropped — it overflows visibly instead of disappearing.
            if !current.indices.isEmpty, widthWithSpacing > maxWidth {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = widthWithSpacing
                current.height = max(current.height, size.height)
            }
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview("Controls") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingProgressBar(completedSteps: 2, stepCount: 6)

            OnboardingHeader(title: "How often does this happen?",
                             subtitle: "Choose everything that applies")

            FlowLayout {
                ChoiceChip(title: "Fatigue", isSelected: true) {}
                ChoiceChip(title: "Sleep", isSelected: false) {}
                ChoiceChip(title: "Dizziness", isSelected: false) {}
            }

            ChoiceRow(title: "Every day", isSelected: true) {}
            ChoiceRow(title: "Once a week", isSelected: false) {}

            MarkerRow(text: "Sleep and heart rate", marker: Palette.positive)

            FieldSurface {
                Text("Name")
                    .font(Typography.fieldText)
                    .foregroundStyle(Palette.placeholder)
            }
        }
        .padding(24)
    }
    .background(Palette.surface)
}
