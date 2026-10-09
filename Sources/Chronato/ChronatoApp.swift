import AppKit
import ChronatoCore
import SwiftUI

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// The status item, its menu, the panels and the windows are AppKit
/// (MenuBarController, AppWindows), as in HoldFn and Meetfacts. SwiftUI has no
/// public way to open its own scenes from an AppKit menu, so this App only
/// provides the main menu: the Edit menu (⌘C, ⌘V in the panels) and, while a
/// window makes Chronato a regular app, the app menu, whose Settings… opens the
/// same window as the status menu's.
struct ChronatoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { AppWindows.shared.showSettings() }.keyboardShortcut(",")
                }
            }
    }
}

/// Reports and Settings: AppKit windows hosting the SwiftUI views (spec §7),
/// opened from the menu. While one is open Chronato is a regular app (Dock
/// tile, ⌘-Tab, its own menu bar); closing the last makes it an accessory again.
@MainActor
final class AppWindows: NSObject, NSWindowDelegate {
    static let shared = AppWindows()
    private var reports: NSWindow?
    private var settings: NSWindow?

    func showReports() {
        let window = reports ?? {
            let host = NSHostingController(rootView: ReportsView().environment(TrackerStore.shared))
            // The SwiftUI .toolbar becomes the window's NSToolbar; never below the content's minimum.
            host.sceneBridgingOptions = [.toolbars, .title]
            host.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = "Chronato Reports"
            window.isReleasedWhenClosed = false
            window.delegate = self
            // The period title is in the content, once (§8).
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 960, height: 680))
            window.contentMinSize = NSSize(width: 760, height: 540)
            return autosaved(window, as: "Reports")
        }()
        reports = window
        present(window)
    }

    /// `tab`: open on that tab (Connect to Kimai… → Connection).
    func showSettings(tab: SettingsTab? = nil) {
        let window = settings ?? {
            let window = SettingsWindow.make(store: .shared)
            window.delegate = self
            return autosaved(window, as: "Settings")
        }()
        settings = window
        if let tab { (window.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = tab.index }
        present(window)
    }

    /// The saved frame, else centred; saved from now on.
    private func autosaved(_ window: NSWindow, as name: String) -> NSWindow {
        if !window.setFrameUsingName(name) { window.center() }
        window.setFrameAutosaveName(name)
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let stillOpen = [reports, settings].compactMap { $0 }.contains { $0 !== closing && ($0.isVisible || $0.isMiniaturized) }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only, also when run straight from .build without Info.plist.
        NSApp.setActivationPolicy(.accessory)
        Prefs.register()
        AppearanceMode.follow()
        menuBar = MenuBarController(store: .shared)
        // Synchronously, before launch completes: a notification action that launched the app reaches us.
        Notifications.shared.setUp()
        Task { @MainActor in await TrackerStore.shared.bootstrap() }
        Updater.shared.start()
    }

    /// The timer runs on in Kimai without Chronato: ask first. Never during logout,
    /// restart or shutdown (a question would hold them up); the next launch treats
    /// the gap like a sleep then.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = TrackerStore.shared
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard store.isRunning, !systemQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A timer is running"
        alert.informativeText = "Without Chronato it keeps running in Kimai. When Chronato starts again, "
            + "time without activity on this Mac is handled like sleep."
        for title in ["Pause & Quit", "Stop & Quit", "Quit, Keep Running", "Cancel"] { alert.addButton(withTitle: title) }
        NSApp.activate()
        let choice: TrackerStore.QuitChoice
        switch alert.runModal() {
        case .alertFirstButtonReturn: choice = .pause
        case .alertSecondButtonReturn: choice = .stop
        case .alertThirdButtonReturn: return .terminateNow // applicationWillTerminate keeps the last input
        default: return .terminateCancel
        }
        Task { @MainActor in
            var quit = true
            if let error = await store.prepareToQuit(choice) {
                let failed = NSAlert()
                failed.messageText = choice == .pause ? "Couldn't pause the timer" : "Couldn't stop the timer"
                failed.informativeText = "\(error.localizedDescription)\n\nIt is still running in Kimai."
                failed.addButton(withTitle: "Cancel")
                failed.addButton(withTitle: "Quit Anyway")
                quit = failed.runModal() == .alertSecondButtonReturn
            }
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        TrackerStore.shared.recordLastAlive()
    }
}
