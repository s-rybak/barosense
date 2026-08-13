import SwiftUI

/// One column of a spinning wheel, drawn on `Palette` rather than on the system trait
/// collection.
///
/// ## Why this is not a `DatePicker`
///
/// `DatePicker` under `.wheel` is a `UIDatePicker` behind the style: it takes its digit colour
/// from the trait collection and ignores `foregroundStyle`, so on this app's light surfaces it
/// renders washed out with no supported way to pull it onto `Palette`. A `Picker`'s rows are
/// ordinary `Text` and carry the same ink as every other control.
///
/// The rows are styled here rather than by the caller so two columns standing side by side —
/// and two screens using them — cannot drift apart. Same reason `ChoiceBackground` exists in
/// `OnboardingComponents`.
struct WheelColumn<Value: Hashable>: View {

    @Binding var selection: Value

    let values: [Value]

    /// Built by the caller: a wheel row is a clock reading, a month name or a year, and only
    /// the caller knows which of those is app copy and which is a formatted number.
    let label: (Value) -> Text

    /// Three rows at the wheel's natural row height: the selected one and a neighbour either
    /// side, which is what makes it read as something that scrolls rather than a boxed label.
    /// A frame shorter than this cuts the two neighbours in half.
    ///
    /// `nonisolated` so a caller can size a layout constant from it. `View` conformance puts
    /// this type on the main actor, and a `Metrics` enum reading it would otherwise be
    /// initialising a nonisolated constant from an isolated one.
    nonisolated static var standardHeight: CGFloat { 160 }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(values, id: \.self) { value in
                label(value)
                    .font(Typography.fieldText)
                    // Harmless on a month name and load-bearing on everything else: without it
                    // a wheel of numbers shifts sideways as the digits under the selection
                    // change width.
                    .monospacedDigit()
                    .foregroundStyle(Palette.heading)
                    .tag(value)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.wheel)
        .labelsHidden()
    }
}

#Preview {
    @Previewable @State var hour = 9
    @Previewable @State var minute = 41

    HStack(spacing: 0) {
        WheelColumn(selection: $hour, values: Array(0...23)) {
            Text(verbatim: String(format: "%02d", $0))
        }

        WheelColumn(selection: $minute, values: Array(0...59)) {
            Text(verbatim: String(format: "%02d", $0))
        }
    }
    .frame(height: WheelColumn<Int>.standardHeight)
    .padding(24)
    .background(Palette.surface)
}
