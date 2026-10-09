import AppKit
import ChronatoCore
import SwiftUI

/// `Chronato snapshot <dir>`: renders the main surfaces with fixture data into
/// PNGs, light and dark, and writes the status menu of every preview state as
/// text (menu-<state>.txt), without showing a window or touching the network.
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

        // The menu, one file per state of the spec's state contract (§4.3), plus an update found.
        for state in TrackerStore.PreviewState.allCases {
            writeMenu(MenuBarController(store: .preview(state), statusItem: false), to: dir.appendingPathComponent("menu-\(state.rawValue).txt"))
        }
        let updating = MenuBarController(store: .preview(.idle), statusItem: false)
        updating.availableUpdate = { "1.2.0" }
        writeMenu(updating, to: dir.appendingPathComponent("menu-updateAvailable.txt"))

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for state in TrackerStore.PreviewState.allCases {
                render(StatusButton(look: StatusLook(.preview(state), showCustomer: false)).padding(6), appearance: appearance,
                       to: dir.appendingPathComponent("statusitem-\(state.rawValue)-\(name).png"))
            }
            render(StatusButton(look: StatusLook(.preview(.running), showCustomer: true)).padding(6), appearance: appearance,
                   to: dir.appendingPathComponent("statusitem-running-customer-\(name).png"))

            for state in [TrackerStore.PreviewState.running, .paused] {
                let store = TrackerStore.preview(state)
                guard let model = NoteModel(store) else { continue }
                render(NoteForm(model: model).environment(store), appearance: appearance, to: dir.appendingPathComponent("note-\(state.rawValue)-\(name).png"))
                if state == .running {
                    model.error = "The request timed out."
                    render(NoteForm(model: model).environment(store), appearance: appearance, to: dir.appendingPathComponent("note-error-\(name).png"))
                }
            }

            // The fixture's last choice is Weekly sync: it comes first.
            for (label, state, query) in [("empty", TrackerStore.PreviewState.running, ""), ("search", .running, "nor auto"),
                                          ("nomatch", .running, "zebra"), ("offline", .offline, "")] {
                let store = TrackerStore.preview(state)
                let model = NewTimerModel(store, last: (project: 12, activity: 5))
                model.query = query
                render(NewTimerForm(model: model).environment(store).frame(width: 440, height: 400), appearance: appearance,
                       to: dir.appendingPathComponent("newtimer-\(label)-\(name).png"))
            }

            for tab in SettingsTab.allCases {
                render(SettingsView(tab: tab).environment(TrackerStore.preview(.idle)), appearance: appearance,
                       to: dir.appendingPathComponent("settings-\(tab.rawValue)-\(name).png"))
            }
            render(ReportsView(fixture: ReportsView.fixtureEntries()).environment(TrackerStore.preview(.idle)).frame(width: 880, height: 640),
                   appearance: appearance, to: dir.appendingPathComponent("reports-\(name).png"))
        }
        print("✓ snapshots in \(dir.path)")
    }

    @MainActor private static func writeMenu(_ controller: MenuBarController, to url: URL) {
        controller.build()
        try? (MenuBarController.dump(controller.menu.items) + "\n").write(to: url, atomically: true, encoding: .utf8)
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
        // Let SwiftUI settle (onAppear/task bodies, async layout), then fit again.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        fit()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        fit()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The status item's button as the menu bar gets it: same image, title, font.
private struct StatusButton: NSViewRepresentable {
    let look: StatusLook

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.font = MenuBarController.titleFont
        look.apply(to: button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {}
}
