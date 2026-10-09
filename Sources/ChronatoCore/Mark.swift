import CoreGraphics
import Foundation

/// The mark, Progress C: one thick ring cut in two, the arc (the time
/// tracked) and the dot (now) on the same centre line, just ahead of the
/// arc's head. The head ends in a straight radial cut, the tail round.
/// Here so the Mac (About, menu bar) and the iPhone (Dynamic Island) draw the
/// same geometry. A copy of `Ring` and `Mark` in scripts/make-icon.swift,
/// which draws the icons and the SVGs: change both together (Branding/brand.md).
/// Grid units, y up, degrees counter-clockwise from 3 o'clock.
public struct MarkRing: Sendable {
    public var center: CGPoint
    public var radius: CGFloat  // centre line of the band
    public var weight: CGFloat  // band width
    public var diameter: CGFloat  // the dot
    public var dotAngle: CGFloat
    public var cut: CGFloat  // clear distance, head's cut → dot
    public var mouth: CGFloat  // clear distance, dot → tail's round cap

    /// The 64-unit master.
    public static let master = MarkRing(center: CGPoint(x: 33, y: 32), radius: 14, weight: 9, diameter: 9.4, dotAngle: 42, cut: 2.4, mouth: 6)

    /// On the Mac's 18 pt menu-bar canvas. Same centre line and dot in both states.
    /// Idle closes the track round the dot (hairline gaps that close up at 1x):
    /// no open end, so it never reads as a spinner or a refresh arrow.
    public static func glyph(running: Bool) -> MarkRing {
        MarkRing(center: CGPoint(x: 9, y: 9), radius: 5.5, weight: running ? 3 : 1.5, diameter: 3.4, dotAngle: 42,
                 cut: running ? 1.2 : 0.4, mouth: running ? 2.2 : 0.4)
    }

    private func angle(chord: CGFloat) -> CGFloat { 2 * asin(chord / (2 * radius)) }
    private func point(_ radians: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
    }

    public var arc: CGPath {
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

    public var dot: CGPath {
        let c = point(dotAngle * .pi / 180)
        return CGPath(ellipseIn: CGRect(x: c.x - diameter / 2, y: c.y - diameter / 2, width: diameter, height: diameter), transform: nil)
    }
}
