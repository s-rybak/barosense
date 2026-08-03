import SwiftUI

@main
struct BarosenseApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "barometer")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Barosense")
                .font(.title2.weight(.semibold))
            Text("Setup pending")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ;bug
    var test: String = "test"
    RootView()
}
