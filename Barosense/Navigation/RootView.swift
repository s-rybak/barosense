import SwiftUI

/// Root container: the selected destination with the custom tab bar pinned to the bottom.
struct RootView: View {

    @State private var selection: AppTab = .now

    var body: some View {
        ZStack {
            Palette.surface.ignoresSafeArea()

            // Every destination is still a placeholder. As a real screen lands, switch
            // on `selection` here and route that one case to it.
            PlaceholderScreen(tab: selection)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BarosenseTabBar(selection: $selection)
        }
        // The Figma library defines a single warm light theme; there is no dark variant
        // to switch to yet, so the app does not follow the system appearance.
        .preferredColorScheme(.light)
    }
}

#Preview {
    RootView()
}
