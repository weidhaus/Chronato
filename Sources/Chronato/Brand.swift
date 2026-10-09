import AppKit
import SwiftUI

/// Chronato's colours and marks. One accent (tomato), graphite and silver
/// around it; everything else is the system's.
enum Brand {
    /// Tomato: running state, primary buttons, the mark's hand. Studio holds the
    /// tokens and their rules (ink for text, fill for marks).
    static let accent = Studio.accentFill
    static let graphite = Color(red: 0x1E / 255, green: 0x1F / 255, blue: 0x22 / 255)
    static let silver = Color(red: 0xC9 / 255, green: 0xCC / 255, blue: 0xD1 / 255)

    /// 18 pt template image for the menu bar: the C-stopwatch mark, redrawn
    /// for this size (the 64-unit master lives in scripts/make-icon.swift).
    /// Idle is a light ring and crown; running thickens them and adds the hand
    /// and pivot, so the state reads at a glance without colour.
    /// The handler is `@Sendable` because AppKit calls it on whatever thread
    /// draws the image; otherwise Swift 6 pins it to the main actor and traps.
    @MainActor static func menuBarGlyph(running: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { @Sendable _ in
            let weight: CGFloat = running ? 2.1 : 1.6
            let center = CGPoint(x: 9.6, y: 7.6)
            let radius: CGFloat = 5.5
            NSColor.black.set()

            // Ring open on the right like a C (gap ±40°, as in the master).
            let ring = NSBezierPath()
            ring.appendArc(withCenter: center, radius: radius, startAngle: 40, endAngle: 320)
            ring.lineWidth = weight
            ring.lineCapStyle = .round
            ring.stroke()

            // Crown: a stem up from the ring to a wider button.
            let buttonY = center.y + radius + weight / 2 + 0.7
            NSBezierPath(rect: NSRect(x: center.x - weight * 0.4, y: center.y + radius, width: weight * 0.8, height: buttonY - center.y - radius + 0.2)).fill()
            let button = NSRect(x: center.x - 2.3, y: buttonY, width: 4.6, height: weight * 0.9)
            NSBezierPath(roundedRect: button, xRadius: button.height * 0.4, yRadius: button.height * 0.4).fill()

            if running {
                // Hand to 2 o'clock and the pivot dot.
                let hand = NSBezierPath()
                hand.move(to: center)
                hand.line(to: CGPoint(x: center.x + 2.8 * cos(.pi / 6), y: center.y + 2.8 * sin(.pi / 6)))
                hand.lineWidth = 1.6
                hand.lineCapStyle = .round
                hand.stroke()
                NSBezierPath(ovalIn: NSRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = running ? "Chronato, timer running" : "Chronato"
        return image
    }

    /// Kimai colours come as "#RRGGBB".
    static func color(hex: String?) -> Color? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// "1:05" (h:mm) for the menu bar, "1:05:09" with seconds for the menu's running line.
enum DurationText {
    static func short(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }

    static func long(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "7.50 h" for reports: the user's decimal mark and grouping (like the % and
    /// currency next to it), always two decimals so a column lines up and quarter hours stay exact.
    static func hours(_ seconds: Int, locale: Locale = .current) -> String {
        (Double(max(0, seconds)) / 3600).formatted(.number.precision(.fractionLength(2)).locale(locale)) + " h"
    }
}
