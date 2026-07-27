import SwiftUI

@main
struct BarosenseWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}

struct WatchRootView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "barometer")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Barosense")
                .font(.headline)
        }
    }
}

#Preview {
    WatchRootView()
}
