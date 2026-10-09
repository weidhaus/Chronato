import AppKit
import SwiftUI

/// Chronato's colours and marks. One accent (tomato), graphite and silver
/// around it; everything else is the system's.
enum Brand {
    /// Tomato: running state, primary buttons, the mark's dot. Studio holds the
    /// tokens and their rules (ink for text, fill for marks).
    static let accent = Studio.accentFill
    static let graphite = Color(red: 0x1E / 255, green: 0x1F / 255, blue: 0x22 / 255)
    static let silver = Color(red: 0xC9 / 255, green: 0xCC / 255, blue: 0xD1 / 255)

    /// 18 pt template image for the menu bar, an optical redraw of the mark.
    /// Idle is a thin closed track with the dot set into it, a dial at rest;
    /// running fills the track to the heavy C. A different shape and weight,
    /// so the state reads at a glance without colour, at 1x too.
    /// The handler is `@Sendable` because AppKit calls it on whatever thread
    /// draws the image; otherwise Swift 6 pins it to the main actor and traps.
    @MainActor static func menuBarGlyph(running: Bool) -> NSImage {
        let ring = MarkRing.glyph(running: running)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { @Sendable _ in
            NSColor.black.set()
            NSBezierPath(cgPath: ring.arc).fill()
            NSBezierPath(cgPath: ring.dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = running ? "Chronato, timer running" : "Chronato"
        return image
    }

    /// The flat mark (Settings → About): the arc in the text colour, the dot tomato.
    static func mark(size: CGFloat) -> some View {
        ZStack {
            MarkShape(dot: false).fill(Studio.textPrimary)
            MarkShape(dot: true).fill(Studio.accentFill)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Kimai colours come as "#RRGGBB".
    static func color(hex: String?) -> Color? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// The mark, Progress C: one thick ring cut in two, the arc (the time
/// tracked) and the dot (now) on the same centre line, just ahead of the
/// arc's head. The head ends in a straight radial cut, the tail round.
/// A copy of `Ring` and `Mark` in scripts/make-icon.swift, which draws the
/// icons and the SVGs: change both together (Branding/brand.md).
/// Grid units, y up, degrees counter-clockwise from 3 o'clock.
struct MarkRing {
    var center: CGPoint
    var radius: CGFloat  // centre line of the band
    var weight: CGFloat  // band width
    var diameter: CGFloat  // the dot
    var dotAngle: CGFloat
    var cut: CGFloat  // clear distance, head's cut → dot
    var mouth: CGFloat  // clear distance, dot → tail's round cap

    /// The 64-unit master.
    static let master = MarkRing(center: CGPoint(x: 33, y: 32), radius: 14, weight: 9, diameter: 9.4, dotAngle: 42, cut: 2.4, mouth: 6)

    /// On an 18 pt canvas. Same centre line and dot in both states.
    static func glyph(running: Bool) -> MarkRing {
        MarkRing(center: CGPoint(x: 9, y: 9), radius: 5.5, weight: running ? 3 : 1.5, diameter: 3.4, dotAngle: 42,
                 cut: 1.2, mouth: running ? 2.2 : 1.2)
    }

    private func angle(chord: CGFloat) -> CGFloat { 2 * asin(chord / (2 * radius)) }
    private func point(_ radians: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
    }

    var arc: CGPath {
        let a = dotAngle * .pi / 180
        let head = a + angle(chord: diameter / 2 + cut)
        let tail = a - angle(chord: diameter / 2 + mouth + weight / 2)
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius + weight / 2, startAngle: head, endAngle: tail + 2 * .pi, clockwise: false)
        path.addArc(center: point(tail), radius: weight / 2, startAngle: tail, endAngle: tail + .pi, clockwise: false)
        path.addArc(center: center, radius: radius - weight / 2, startAngle: tail + 2 * .pi, endAngle: head, clockwise: true)
        path.closeSubpath()
        return path
    }

    var dot: CGPath {
        let c = point(dotAngle * .pi / 180)
        return CGPath(ellipseIn: CGRect(x: c.x - diameter / 2, y: c.y - diameter / 2, width: diameter, height: diameter), transform: nil)
    }
}

/// One piece of the master, scaled into the view (whose y points down).
private struct MarkShape: Shape {
    let dot: Bool

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 64
        let part = dot ? MarkRing.master.dot : MarkRing.master.arc
        return Path(part).applying(CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: rect.minX, ty: rect.minY + 64 * scale))
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
