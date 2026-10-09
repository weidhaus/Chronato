import AppKit
import ChronatoCore
import SwiftUI

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

struct ChronatoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = TrackerStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environment(store)
        } label: {
            MenuBarLabel().environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(store)
        }

        Window("Chronato Reports", id: "reports") {
            ReportsView().environment(store)
        }
        .defaultSize(width: 960, height: 680)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only, also when run straight from .build without Info.plist.
        NSApp.setActivationPolicy(.accessory)
        Prefs.register()
        AppearanceMode.follow()
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
