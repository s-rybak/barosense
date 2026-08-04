import SwiftUI

/// Stand-in for a destination that has not been built yet.
///
/// It exists so the tab bar is navigable end to end and it is obvious which destination
/// is selected. Each case gets a real screen type as it lands; this file shrinks as they
/// do and is deleted when the last one is replaced.
struct PlaceholderScreen: View {

    let tab: AppTab

    var body: some View {
        VStack(spacing: 10) {
            Text(tab.screenTitle)
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.ink)

            Text(tab.screenSummary)
                .font(Typography.screenSummary)
                .foregroundStyle(Palette.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    PlaceholderScreen(tab: .now)
        .background(Palette.surface)
}
