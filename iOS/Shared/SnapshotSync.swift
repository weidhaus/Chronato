import WidgetKit

/// Where a new snapshot goes besides the App Group file: the Live Activity,
/// the widget timelines and Siri's shortcut phrases. PhoneTracker calls it
/// after every change, in whichever process it runs.
@MainActor
enum SnapshotSync {
    private static var pendingReload: Task<Void, Never>?

    static func didPublish(_ snapshot: SharedSnapshot) {
        LiveActivitySync.sync(snapshot)
        scheduleReload()
        #if !WIDGET_EXTENSION
        // "Start <activity> in Chronato" phrases come from the recent list.
        ChronatoShortcuts.updateAppShortcutParameters()
        #endif
    }

    /// One reload for a burst of snapshots (an action publishes, then its
    /// refresh may publish again): WidgetKit budgets reloads.
    private static func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            pendingReload = nil
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Reload now if one is pending. Intents call it before they return: a
    /// background launch may be suspended before the debounce fires.
    static func flush() {
        guard let pending = pendingReload else { return }
        pending.cancel()
        pendingReload = nil
        WidgetCenter.shared.reloadAllTimelines()
    }
}
