import AppKit
import ChronatoCore
import SwiftUI

/// `Chronato snapshot <dir>`: renders the main surfaces with fixture data into
/// PNGs, light and dark, without showing a window or touching the network.
/// This is how the UI is checked without clicking around a real desktop.
enum Snapshot {
    @MainActor static func run(_ args: [String]) {
        let dir = URL(fileURLWithPath: args.first ?? "snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Fixture data only: an empty scratch home, so no view reads the developer's
        // real agents.json or AI sessions (the PNGs end up in a public README).
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("chronato-snapshot-\(UUID().uuidString)")
        setenv("CHRONATO_HOME", home.path, 1)
        defer { try? FileManager.default.removeItem(at: home) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for state in TrackerStore.PreviewState.allCases {
                let store = TrackerStore.preview(state)
                render(MenuPanel().environment(store), appearance: appearance, to: dir.appendingPathComponent("panel-\(state.rawValue)-\(name).png"))
            }
            // A screen too small for the panel: the middle scrolls, totals and footer stay.
            render(MenuPanel(maxMiddleHeight: 380).environment(TrackerStore.preview(.running)), appearance: appearance,
                   to: dir.appendingPathComponent("panel-scrolled-\(name).png"))
            let store = TrackerStore.preview(.running)
            render(HStack(spacing: 8) { MenuBarLabel().environment(store) }.padding(6),
                   appearance: appearance, to: dir.appendingPathComponent("menubar-running-\(name).png"))
            for tab in SettingsTab.allCases {
                render(SettingsWindowController.makeWindow(store: TrackerStore.preview(.idle), tab: tab), appearance: appearance,
                       to: dir.appendingPathComponent("settings-\(tab.rawValue)-\(name).png"))
            }
            render(ReportsView(fixture: ReportsView.fixtureEntries()).environment(TrackerStore.preview(.idle)).frame(width: 880, height: 640),
                   appearance: appearance, to: dir.appendingPathComponent("reports-\(name).png"))
        }
        print("✓ snapshots in \(dir.path)")
    }

    @MainActor static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        func fit() {
            let size = host.fittingSize
            window.setContentSize(CGSize(width: max(size.width, 40), height: max(size.height, 20)))
            host.layoutSubtreeIfNeeded()
        }
        fit()
        // Let SwiftUI settle (onAppear/task bodies, async layout), then fit again:
        // measured sizes (the panel's scroll height) arrive only after a layout pass.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        fit()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        fit()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A whole window, title bar and toolbar included, never put on screen.
    @MainActor static func render(_ window: NSWindow, appearance: NSAppearance.Name, to url: URL) {
        window.appearance = NSAppearance(named: appearance)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        // The selected toolbar item's glass draws as a white block off screen;
        // the window title names the tab instead.
        window.toolbar?.selectedItemIdentifier = nil
        guard let frame = window.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("\(url.lastPathComponent): \(window.title), \(Int(window.frame.width))×\(Int(window.frame.height))")
    }
}
