import AppKit
import Sparkle
import SwiftUI

/// Self-updating through Sparkle 2.
///
/// Started from AppDelegate, so `Chronato mcp` and `Chronato snapshot` never
/// get here, and only inside a real Chronato.app whose Info.plist names a
/// feed: a bare `.build` run has no SUFeedURL, and Sparkle would only show an
/// alert that it is misconfigured.
///
/// Chronato lives in the menu bar and is rarely the active app, so scheduled
/// checks use Sparkle's gentle reminders: rather than a window popping up over
/// whatever the user is doing, the menu panel shows a small "Update to x.y.z"
/// button. Sparkle relaunches the app itself after installing, which is right
/// here: the login item is SMAppService, not a LaunchAgent that would need to
/// own the new process.
@MainActor @Observable
final class Updater: NSObject {
    static let shared = Updater()

    /// Found by a scheduled check and not yet looked at; the menu panel offers it.
    private(set) var availableVersion: String?
    /// False until started, and while Sparkle downloads in the background.
    private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    var isRunning: Bool { controller != nil }

    /// Sparkle's own setting, persisted by Sparkle in user defaults. Read and
    /// written through rather than mirrored: copying it into a stored property
    /// at launch would write it back and pin the Info.plist default forever.
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// Call once, after launch.
    func start() {
        guard controller == nil,
              Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        // Sparkle posts changes on the main thread; KVO is how it announces them.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    /// "Check for Updates…", and the reminder button: with an update already
    /// found, Sparkle brings that one forward instead of checking again.
    func checkForUpdates() {
        guard let controller else { return }
        // An accessory app's windows open behind the active app otherwise.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

// Sparkle calls its user-driver delegate on the main thread; the protocol is
// just not annotated, so `@preconcurrency` checks that at run time instead.
extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows a scheduled update itself only when it wants utmost focus
    /// (just launched, or the user was idle) and Chronato is the active app.
    /// Otherwise the reminder goes into the menu panel.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus && NSApp.isActive
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { availableVersion = update.displayVersionString }
    }

    /// The user has seen the update window: the reminder has done its job.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    /// Skipped, dismissed or failed: nothing left to offer until the next check.
    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}

// MARK: - UI hooks

/// Menu panel: "Update to x.y.z" once a scheduled check found one; nothing otherwise.
struct UpdateReminderButton: View {
    var body: some View {
        if let version = Updater.shared.availableVersion {
            Button { Updater.shared.checkForUpdates() } label: {
                Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Brand.accent)
        }
    }
}

/// Menu panel footer: a small "Check for Updates…" icon.
struct CheckForUpdatesButton: View {
    var body: some View {
        Button { Updater.shared.checkForUpdates() } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
        .disabled(!Updater.shared.canCheckForUpdates)
        .help("Check for Updates…")
        .accessibilityLabel("Check for Updates")
    }
}

/// Settings → About. Disabled when the updater is not running (dev builds).
struct UpdateSettings: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 8) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                .disabled(!updater.isRunning)
        }
    }
}
