import SwiftUI

@main
struct ChronatoApp: App {
    @State private var tracker = Self.makeTracker()

    var body: some Scene {
        WindowGroup {
            RootView().environment(tracker)
        }
    }

    /// Launch argument `-ChronatoFixture <idle|running|paused|unconfigured>`
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
        .tint(Brand.accent)
        .task { await tracker.bootstrap() }
        // A timer may have been started or stopped in the browser or on the Mac.
        // Not on the first appearance: bootstrap loads then.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await tracker.refresh() } }
        }
    }
}
