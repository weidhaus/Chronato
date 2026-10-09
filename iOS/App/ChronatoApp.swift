import SwiftUI

@main
struct ChronatoApp: App {
    @State private var tracker = Self.makeTracker()

    var body: some Scene {
        WindowGroup {
            RootView().environment(tracker)
        }
    }

    /// Launch argument `-ChronatoFixture <idle|running|paused|unconfigured|offline|error>`
    /// (UserDefaults reads it): fictional data and no network, for screenshots
    /// and UI work. The shared scheme has it, switched off.
    private static func makeTracker() -> PhoneTracker {
        if let raw = UserDefaults.standard.string(forKey: "ChronatoFixture"), let state = PhoneTracker.Fixture(rawValue: raw) {
            return .fixture(state)
        }
        return PhoneTracker()
    }
}

/// Onboarding until a Kimai is connected, then the tabs.
struct RootView: View {
    @Environment(PhoneTracker.self) private var tracker
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system
    /// Launch argument `-ChronatoTab <track|reports|settings>` opens another tab
    /// first, so screenshots can reach every tab without tapping.
    @State private var tab = AppTab(rawValue: UserDefaults.standard.string(forKey: "ChronatoTab") ?? "") ?? .track

    enum AppTab: String { case track, reports, settings }

    var body: some View {
        Group {
            if tracker.connectionState == .unconfigured {
                OnboardingView()
            } else {
                TabView(selection: $tab) {
                    Tab("Track", systemImage: "stopwatch", value: .track) { TrackView() }
                    Tab("Reports", systemImage: "chart.bar.xaxis", value: .reports) { ReportsTab() }
                    Tab("Settings", systemImage: "gearshape", value: .settings) { SettingsView() }
                }
            }
        }
        // Tomato ink: links, toolbar buttons, the selected tab. Fills stay the system's.
        .tint(Studio.accentInk)
        .onAppear { appearance.apply() }
        #if DEBUG
        .task { await ScreenshotScroll.toBottomIfRequested() }
        #endif
        .onChange(of: appearance) { appearance.apply() }
        .task { await tracker.bootstrap() }
        // A timer may have been started or stopped in the browser or on the Mac.
        // Not on the first appearance: bootstrap loads then.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await tracker.refresh() } }
        }
    }
}

#if DEBUG
/// Debug aid for screenshots: `-ChronatoScroll bottom` scrolls every list on
/// screen to its end shortly after launch, so `simctl io screenshot` reaches
/// what lies below the first screen without anyone touching the simulator.
@MainActor
enum ScreenshotScroll {
    static func toBottomIfRequested() async {
        guard UserDefaults.standard.string(forKey: "ChronatoScroll") == "bottom" else { return }
        try? await Task.sleep(for: .seconds(1.5))
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach(scrollDown)
        }
    }

    private static func scrollDown(_ view: UIView) {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
            let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: bottom), animated: false)
        }
        view.subviews.forEach(scrollDown)
    }
}
#endif
