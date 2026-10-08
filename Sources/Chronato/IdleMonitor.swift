import CoreGraphics
import Foundation

/// How long the user has been away from this Mac. Polled by the store's idle
/// tick (~15 s); the decisions live in `TrackingPolicy`.
enum IdleMonitor {
    static let pollInterval: Duration = .seconds(15)

    /// Seconds since the last keyboard, mouse or trackpad event in this login
    /// session. Reading the HID idle time needs no Accessibility/Input Monitoring
    /// permission, unlike an event tap.
    static func secondsSinceLastInput() -> TimeInterval {
        // ~0 is kCGAnyInputEventType.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
