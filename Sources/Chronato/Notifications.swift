import Foundation
import UserNotifications

/// Local notifications: auto-pause, "welcome back" (with Resume / Count it),
/// the 24 h cap, reaped AI sessions, hot-key feedback.
///
/// Everything is a no-op without a bundle identifier (`swift run`, `.build/`):
/// `UNUserNotificationCenter.current()` traps there.
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()

    static let awayCategory = "away"
    /// Away for long: Resume only; counting that much time needs a confirmation in the menu.
    static let awayLongCategory = "awayLong"
    /// The away notification has a fixed id, so a newer one replaces it and
    /// resolving the notice in the menu can withdraw it.
    static let awayId = "away"
    /// Hot-key feedback: a newer one replaces the last.
    static let hotKeyId = "hotKey"

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    /// Delegate, the away categories' actions, and the permission prompt. Called
    /// by the app delegate before launch completes, so an action that launched the
    /// app is delivered.
    func setUp() {
        guard let center else { return }
        center.delegate = self
        let resume = UNNotificationAction(identifier: "resume", title: "Resume")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.awayCategory, actions: [
                resume, UNNotificationAction(identifier: "resumeCountingAway", title: "Count it"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.awayLongCategory, actions: [resume], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ title: String, _ body: String, id: String = UUID().uuidString, category: String? = nil) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func withdraw(_ id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while Chronato is "active": as an accessory app it often is.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let choice: TrackerStore.AwayChoice? = switch response.actionIdentifier {
        case "resume": .resume
        case "resumeCountingAway": .resumeCountingAway
        default: nil
        }
        guard let choice else { return }
        // The menu is closed: say when it did not work (offline, or too long away to count without asking).
        if let error = await TrackerStore.shared.resolveAway(choice) {
            await post("Chronato didn't do that", error.localizedDescription)
        }
    }
}
