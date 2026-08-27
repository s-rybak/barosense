import SwiftUI

/// How much bottom safe area `BarosenseTabBar` is taking up, for the screens that have to put
/// it back by hand.
///
/// `RootView` hands the bar down as a `safeAreaInset`, which is all a screen needs when its
/// content sits directly inside it — the Now screen's list ends above the bar without asking
/// for anything. It is **not** enough for a screen that owns a `NavigationStack`: the stack
/// gives its root the container's own safe area — the home indicator and nothing else — and
/// drops the inset added above it. Measured on an iPhone 17 Pro: 124 pt immediately outside the
/// stack, 34 pt immediately inside it. A `ScrollView` in that position runs its content under
/// the bar, and whatever sits at the end of it cannot be scrolled clear.
///
/// Measured rather than derived. The bar's height follows `@ScaledMetric` and changes with the
/// user's type size, so a second copy of its layout arithmetic here would be wrong the first
/// time either that or the design moved.
private struct TabBarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {

    /// Height of the tab bar `RootView` is currently showing, and zero wherever it is not
    /// showing one — a preview, a test, or a screen hosted outside the root. A screen applies
    /// it as `.safeAreaPadding(.bottom, tabBarInset)` on the scrolling root **inside** its
    /// `NavigationStack`; anywhere else it is already accounted for and would double up.
    var tabBarInset: CGFloat {
        get { self[TabBarInsetKey.self] }
        set { self[TabBarInsetKey.self] = newValue }
    }
}
