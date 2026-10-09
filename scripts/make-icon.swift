#!/usr/bin/env swift
// Draws Chronato's mark and app icons with CoreGraphics.
//
//   swift scripts/make-icon.swift Branding
//
// Writes into <dir>:
//   AppIcon.icns            every macOS iconset size (the fallback beside the Icon Composer icon)
//   logo-1024.png           that macOS icon at 1024 px, for presentations
//   AppIcon-iOS-1024.png    the iPhone icon: full bleed, no alpha. Copy it to
//                           iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//   mark.svg, logo.svg      the flat mark: one colour (currentColor), and the README's two-colour logo
//   Chronato.icon/Assets/   arc.svg and dot.svg, the Icon Composer layers (icon.json is edited by hand
//                           or in Icon Composer; this script never touches it)
//   brand-board.png         every size, the menu-bar glyph, the lockup and the colours on one board
//
// The mark, "Progress C", is defined once below (`Ring`, `Mark.master`) on a
// 64-unit grid. Brand.swift draws the same mark and the menu-bar glyph in the
// app: change both together.

import AppKit
import UniformTypeIdentifiers

// MARK: - The mark (64-unit grid, y up, angles in degrees counter-clockwise from 3 o'clock)

/// One thick ring cut in two: the arc, the time already tracked, and the dot,
/// now, on the same centre line just ahead of the arc's head (clockwise).
/// The head ends in a straight radial cut, the "tick" before the dot; the tail
/// ends round. The wide gap between the dot and the tail is the C's mouth.
struct Ring {
    var center: CGPoint
    var radius: CGFloat    // centre line of the band
    var weight: CGFloat    // band width
    var dot: CGFloat       // dot diameter
    var dotAngle: CGFloat
    var cut: CGFloat       // clear distance, head's cut → dot
    var mouth: CGFloat     // clear distance, dot → tail's round cap

    func angle(chord: CGFloat) -> CGFloat { 2 * asin(chord / (2 * radius)) * 180 / .pi }
    var head: CGFloat { dotAngle + angle(chord: dot / 2 + cut) }
    /// Centre of the tail's round cap, below the dot (so less than `dotAngle`).
    var tail: CGFloat { dotAngle - angle(chord: dot / 2 + mouth + weight / 2) }

    func point(_ degrees: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + r * cos(degrees * .pi / 180), y: center.y + r * sin(degrees * .pi / 180))
    }

    /// Outer edge from the head round the left to the tail, the round cap,
    /// the inner edge back, and the head's straight cut.
    var arc: CGPath {
        let rad = { (d: CGFloat) in d * .pi / 180 }
        let p = CGMutablePath()
        p.addArc(center: center, radius: radius + weight / 2, startAngle: rad(head), endAngle: rad(tail + 360), clockwise: false)
        p.addArc(center: point(tail, radius), radius: weight / 2, startAngle: rad(tail), endAngle: rad(tail + 180), clockwise: false)
        p.addArc(center: center, radius: radius - weight / 2, startAngle: rad(tail + 360), endAngle: rad(head), clockwise: true)
        p.closeSubpath()
        return p
    }

    var dotPath: CGPath {
        let c = point(dotAngle, radius)
        return CGPath(ellipseIn: CGRect(x: c.x - dot / 2, y: c.y - dot / 2, width: dot, height: dot), transform: nil)
    }
}

enum Mark {
    /// The master: outer diameter 37 units (58 % of the grid). The dot is 4 %
    /// wider than the band, because a dot reads smaller than a line. Its
    /// bounding box is centred on the grid.
    static let master = Ring(center: CGPoint(x: 33, y: 32), radius: 14, weight: 9, dot: 9.4, dotAngle: 42, cut: 2.4, mouth: 6)

    /// Optical redraw for 16 px icons, where the master's cut is half a pixel:
    /// a larger, bolder ring with a cut and a mouth of at least a pixel.
    static let small = Ring(center: CGPoint(x: 32.5, y: 32), radius: 15, weight: 10, dot: 11, dotAngle: 42, cut: 5, mouth: 8)

    /// The 18 pt menu-bar template, an optical redraw (Brand.menuBarGlyph).
    /// Idle: a thin closed track with the dot set into it, a dial at rest.
    /// Running: the track fills to the heavy C. Same centre line and dot in both.
    static func glyph(running: Bool) -> Ring {
        Ring(center: CGPoint(x: 9, y: 9), radius: 5.5, weight: running ? 3 : 1.5, dot: 3.4, dotAngle: 42,
             cut: 1.2, mouth: running ? 2.2 : 1.2)
    }
}

// MARK: - Colour

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, alpha])!
}

enum Palette {
    static let tomato: UInt32 = 0xE5533D       // the dot; Studio.accentFill
    static let tomatoLight: UInt32 = 0xF2705A  // top of the dot's soft light
    static let graphite: UInt32 = 0x1E1F22     // one-colour mark on light
    static let silver: UInt32 = 0xC9CCD1       // one-colour mark on dark
    static let white: UInt32 = 0xFFFFFF
}

/// Tile, arc and dot, each a top-to-bottom gradient (a soft top light, no bevel).
struct Look {
    var tile: (UInt32, UInt32), arc: (UInt32, UInt32), dot: (UInt32, UInt32)
    /// The default: dark graphite tile, satin white arc, tomato dot.
    static let dark = Look(tile: (0x30333A, 0x141518), arc: (0xFFFFFF, 0xD9DCE0), dot: (Palette.tomatoLight, Palette.tomato))
    /// The light variant: paper tile, graphite arc.
    static let light = Look(tile: (0xFBFAF7, 0xE9E7E2), arc: (0x2C2F35, 0x1C1E22), dot: (Palette.tomatoLight, Palette.tomato))
}

// MARK: - Drawing

func context(_ width: Int, _ height: Int, opaque: Bool = false) -> CGContext {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: info.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

func transformed(_ path: CGPath, _ t: CGAffineTransform) -> CGPath {
    var t = t
    return path.copy(using: &t)!
}

/// The 64-unit grid mapped onto `rect`.
func grid(_ rect: CGRect) -> CGAffineTransform {
    CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / 64, y: rect.height / 64)
}

func fill(_ ctx: CGContext, _ path: CGPath, _ colors: (UInt32, UInt32)) {
    let box = path.boundingBoxOfPath
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: sRGB, colors: [rgb(colors.0), rgb(colors.1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// Rounded rectangle with continuous corners, the app-icon shape: the
/// well-known approximation of Apple's corner curve.
func squircle(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let corner: [(CGFloat, CGFloat)] = [
        (1.08849323, 0), (0.86840689, 0), (0.66993427, 0.06245183), (0.63149399, 0.07491100),
        (0.37282392, 0.16905899), (0.16906013, 0.37282401), (0.07491100, 0.63149399), (0.06245183, 0.66993427),
        (0, 0.86840689), (0, 1.08849323), (0, 1.52866483),
    ]
    // Vertex, direction back along the incoming edge, direction along the outgoing edge.
    let vertices: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + 1.52866483 * r, y: rect.maxY))
    for (v, e1, e2) in vertices {
        func p(_ ab: (CGFloat, CGFloat)) -> CGPoint {
            CGPoint(x: v.x + (ab.0 * e1.dx + ab.1 * e2.dx) * r, y: v.y + (ab.0 * e1.dy + ab.1 * e2.dy) * r)
        }
        path.addLine(to: p((1.52866483, 0)))
        path.addCurve(to: p(corner[2]), control1: p(corner[0]), control2: p(corner[1]))
        path.addLine(to: p(corner[3]))
        path.addCurve(to: p(corner[6]), control1: p(corner[4]), control2: p(corner[5]))
        path.addLine(to: p(corner[7]))
        path.addCurve(to: p(corner[10]), control1: p(corner[8]), control2: p(corner[9]))
    }
    path.closeSubpath()
    return path
}

/// The icon in `canvas`. `fullBleed` (iOS, Icon Composer previews): the tile
/// fills the square and the system rounds it. Otherwise (macOS .icns): the
/// Big Sur grid, an 824 squircle on the 1024 canvas, with a soft drop shadow
/// and a hairline of light along the top edge, as the system draws glass.
func drawIcon(_ ctx: CGContext, in canvas: CGRect, look: Look = .dark, fullBleed: Bool) {
    let k = canvas.width / 1024
    let rect = fullBleed ? canvas : canvas.insetBy(dx: 100 * k, dy: 100 * k)
    let tile = fullBleed ? CGPath(rect: rect, transform: nil) : squircle(rect, radius: rect.width * 0.225)
    ctx.saveGState()
    if !fullBleed {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: rgb(0x000000, 0.35))
        ctx.addPath(tile)
        ctx.setFillColor(rgb(look.tile.1))
        ctx.fillPath()
        ctx.restoreGState()
    }
    fill(ctx, tile, look.tile)
    if !fullBleed {
        // Edge light: the tile minus itself moved down 2.5 units, inside the tile.
        ctx.saveGState()
        ctx.addPath(tile)
        ctx.clip()
        let lip = CGMutablePath()
        lip.addPath(tile)
        lip.addPath(transformed(tile, CGAffineTransform(translationX: 0, y: -2.5 * k)))
        ctx.addPath(lip)
        ctx.setFillColor(rgb(0xFFFFFF, 0.16))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }
    let t = grid(rect), mark = canvas.width <= 16 ? Mark.small : Mark.master
    fill(ctx, transformed(mark.arc, t), look.arc)
    fill(ctx, transformed(mark.dotPath, t), look.dot)
    ctx.restoreGState()
}

func icon(_ pixels: Int, look: Look = .dark, fullBleed: Bool = false) -> CGImage {
    let ctx = context(pixels, pixels, opaque: fullBleed)
    drawIcon(ctx, in: CGRect(x: 0, y: 0, width: pixels, height: pixels), look: look, fullBleed: fullBleed)
    return ctx.makeImage()!
}

// MARK: - SVG

/// SVG path data of a grid path: y flipped, `scale` units per grid unit.
func svgPath(_ path: CGPath, scale: CGFloat = 1) -> String {
    var d: [String] = []
    func p(_ q: CGPoint) -> String { String(format: "%.2f %.2f", q.x * scale, (64 - q.y) * scale) }
    path.applyWithBlock { element in
        let e = element.pointee, pts = e.points
        switch e.type {
        case .moveToPoint: d.append("M" + p(pts[0]))
        case .addLineToPoint: d.append("L" + p(pts[0]))
        case .addQuadCurveToPoint: d.append("Q" + p(pts[0]) + " " + p(pts[1]))
        case .addCurveToPoint: d.append("C" + p(pts[0]) + " " + p(pts[1]) + " " + p(pts[2]))
        case .closeSubpath: d.append("Z")
        @unknown default: break
        }
    }
    return d.joined()
}

func svgDot(_ scale: CGFloat = 1, fill: String) -> String {
    let m = Mark.master, c = m.point(m.dotAngle, m.radius)
    return String(format: "<circle cx=\"%.2f\" cy=\"%.2f\" r=\"%.2f\" fill=\"%@\"/>", c.x * scale, (64 - c.y) * scale, m.dot / 2 * scale, fill)
}

let geometryNote = String(format: """
    Progress C, 64-unit grid, y down. Ring centre (%.0f, %.0f), radius %.0f to the band's centre line, band %.0f.
           The arc runs from a straight cut at %.1f° round the left to a round cap at %.1f° (counter-clockwise
           from 3 o'clock); the dot (d %.1f) sits on the same circle at %.0f°, %.1f clear of the cut.
           Generated by scripts/make-icon.swift.
    """, Mark.master.center.x, 64 - Mark.master.center.y, Mark.master.radius, Mark.master.weight,
    Mark.master.head, Mark.master.tail, Mark.master.dot, Mark.master.dotAngle, Mark.master.cut)

let markSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="256" height="256" role="img" aria-label="Chronato">
      <!-- \(geometryNote)
           One colour: currentColor. -->
      <path d="\(svgPath(Mark.master.arc))" fill="currentColor"/>
      \(svgDot(fill: "currentColor"))
    </svg>

    """

let logoSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="256" height="256" role="img" aria-label="Chronato">
      <!-- \(geometryNote)
           The arc is graphite on light backgrounds and silver on dark; the dot is always tomato. -->
      <style>
        .arc { fill: #1E1F22 }
        @media (prefers-color-scheme: dark) { .arc { fill: #C9CCD1 } }
      </style>
      <path class="arc" d="\(svgPath(Mark.master.arc))"/>
      \(svgDot(fill: "#E5533D"))
    </svg>

    """

/// Icon Composer layers: the 1024-point canvas, flat colour. The system adds
/// the glass, the light and the shadow.
func layerSVG(_ body: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
      \(body)
    </svg>

    """
}

// MARK: - Board

@discardableResult
func text(_ ctx: CGContext, _ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
          color: UInt32 = 0x6B6E73, mono: Bool = false, kern: CGFloat = 0) -> CGFloat {
    let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: rgb(color))!, .kern: kern]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    ctx.textPosition = p
    CTLineDraw(line, ctx)
    return CTLineGetTypographicBounds(line, nil, nil, nil)
}

/// A template glyph at `origin` (px), `scale` px per pt.
func drawGlyph(_ ctx: CGContext, running: Bool, at origin: CGPoint, scale: CGFloat, color: CGColor) {
    let g = Mark.glyph(running: running), t = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)
    ctx.addPath(transformed(g.arc, t))
    ctx.addPath(transformed(g.dotPath, t))
    ctx.setFillColor(color)
    ctx.fillPath()
}

/// A menu-bar strip `width` pt wide at `origin` (px), `s` px per pt: idle,
/// running with its title, paused (idle and the 7 pt pause badge), a clock.
func menuBar(_ ctx: CGContext, at origin: CGPoint, width: CGFloat, s: CGFloat, dark: Bool, clock: Bool = true) {
    ctx.setFillColor(rgb(dark ? 0x232427 : 0xEDEDEF))
    ctx.fill(CGRect(x: origin.x, y: origin.y, width: width * s, height: 24 * s))
    let ink: UInt32 = dark ? 0xFFFFFF : 0x000000, color = rgb(ink, dark ? 1 : 0.85)
    let gy = origin.y + 3 * s, baseline = origin.y + 7.5 * s
    var x = origin.x + 14 * s
    drawGlyph(ctx, running: false, at: CGPoint(x: x, y: gy), scale: s, color: color)
    x += 46 * s
    drawGlyph(ctx, running: true, at: CGPoint(x: x, y: gy), scale: s, color: color)
    text(ctx, "1:23", at: CGPoint(x: x + 22 * s, y: baseline), size: 13 * s, color: ink, mono: true)
    x += 80 * s
    drawGlyph(ctx, running: false, at: CGPoint(x: x, y: gy), scale: s, color: color)
    if let pause = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 7 * s, weight: .heavy)),
       let cg = pause.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let r = CGRect(x: x + 20 * s, y: origin.y + 12 * s - pause.size.height / 2, width: pause.size.width, height: pause.size.height)
        ctx.saveGState()
        ctx.clip(to: r, mask: cg)
        ctx.setFillColor(color)
        ctx.fill(r)
        ctx.restoreGState()
    }
    guard clock else { return }
    let time = "Thu 9 Oct  14:05"
    let w = NSAttributedString(string: time, attributes: [.font: NSFont.systemFont(ofSize: 13 * s)]).size().width
    text(ctx, time, at: CGPoint(x: origin.x + width * s - 14 * s - w, y: baseline), size: 13 * s, color: ink)
}

func drawBoard() -> CGImage {
    let W = 1600, H = 1060
    let ctx = context(W, H, opaque: true)
    ctx.setFillColor(rgb(0xE4E3DF))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let ink: UInt32 = 0x1E1F22
    text(ctx, "CHRONATO", at: CGPoint(x: 60, y: 1008), size: 15, weight: .semibold, color: ink, kern: 1.5)
    text(ctx, "Progress C · the arc is the time tracked, the tomato dot is now", at: CGPoint(x: 168, y: 1008), size: 15, weight: .medium)

    // Hero: the default icon as the system masks it.
    drawIcon(ctx, in: CGRect(x: 60, y: 470, width: 480, height: 480), fullBleed: false)
    text(ctx, "App icon · default: dark graphite tile", at: CGPoint(x: 100, y: 470), size: 14, weight: .medium)

    // Sizes, real pixels.
    var x: CGFloat = 620
    for px in [256, 128, 64, 32, 16] {
        ctx.draw(icon(px), in: CGRect(x: x, y: 700, width: CGFloat(px), height: CGFloat(px)))
        text(ctx, "\(px)", at: CGPoint(x: x + CGFloat(px) / 2 - 8, y: 676), size: 12)
        x += CGFloat(px) + 20
    }
    ctx.draw(icon(128, look: .light), in: CGRect(x: x + 20, y: 700, width: 128, height: 128))
    text(ctx, "Light variant", at: CGPoint(x: x + 44, y: 676), size: 12)

    // Lockup: the icon tile beside the wordmark, never the bare mark (it would read "C Chronato").
    for (i, dark) in [false, true].enumerated() {
        let box = CGRect(x: 620 + CGFloat(i) * 470, y: 520, width: 450, height: 120)
        ctx.setFillColor(rgb(dark ? 0x1C1D20 : 0xFFFFFF))
        ctx.fill(box)
        ctx.draw(icon(160), in: CGRect(x: box.minX + 22, y: box.minY + 20, width: 80, height: 80))
        text(ctx, "Chronato", at: CGPoint(x: box.minX + 112, y: box.minY + 44), size: 46, weight: .semibold,
             color: dark ? 0xF4F6F5 : ink, kern: -0.8)
    }
    text(ctx, "Lockup: the icon tile, then the wordmark in the system font. The bare mark stands alone.",
         at: CGPoint(x: 620, y: 496), size: 12)

    // Menu bar: Retina, then non-Retina with every pixel doubled.
    menuBar(ctx, at: CGPoint(x: 620, y: 400), width: 460, s: 2, dark: false)
    menuBar(ctx, at: CGPoint(x: 620, y: 344), width: 460, s: 2, dark: true)
    for (i, dark) in [false, true].enumerated() {
        let small = context(220, 24)
        menuBar(small, at: .zero, width: 220, s: 1, dark: dark, clock: false)
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(small.makeImage()!, in: CGRect(x: 620 + CGFloat(i) * 460, y: 280, width: 440, height: 48))
        ctx.restoreGState()
    }
    text(ctx, "Menu bar, 18 pt template · idle: the dial at rest · running: the track fills to the C, with h:mm · paused · "
         + "top @2x, bottom @1x (pixels doubled)", at: CGPoint(x: 620, y: 256), size: 12)

    // The flat mark: two colours, then one colour on light and on dark.
    let marks: [(UInt32, UInt32, UInt32)] = [(0xFFFFFF, Palette.graphite, Palette.tomato), (0xFFFFFF, Palette.graphite, Palette.graphite),
                                             (0x1C1D20, Palette.silver, Palette.tomato), (0x1C1D20, Palette.silver, Palette.silver)]
    for (i, (bg, arc, dot)) in marks.enumerated() {
        let box = CGRect(x: 60 + CGFloat(i) * 122, y: 280, width: 110, height: 110)
        ctx.setFillColor(rgb(bg))
        ctx.fill(box)
        let t = grid(box.insetBy(dx: 12, dy: 12))
        ctx.addPath(transformed(Mark.master.arc, t)); ctx.setFillColor(rgb(arc)); ctx.fillPath()
        ctx.addPath(transformed(Mark.master.dotPath, t)); ctx.setFillColor(rgb(dot)); ctx.fillPath()
    }
    text(ctx, "Flat mark: graphite or silver, the dot tomato or the same one colour", at: CGPoint(x: 60, y: 256), size: 12)

    // Construction: the master on its grid.
    let cbox = CGRect(x: 60, y: 60, width: 170, height: 170)
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(cbox)
    let ct = grid(cbox)
    ctx.setStrokeColor(rgb(0x000000, 0.08)); ctx.setLineWidth(1)
    for i in stride(from: 0, through: 64, by: 8) {
        let v = CGFloat(i) * cbox.width / 64
        ctx.move(to: CGPoint(x: cbox.minX + v, y: cbox.minY)); ctx.addLine(to: CGPoint(x: cbox.minX + v, y: cbox.maxY))
        ctx.move(to: CGPoint(x: cbox.minX, y: cbox.minY + v)); ctx.addLine(to: CGPoint(x: cbox.maxX, y: cbox.minY + v))
    }
    ctx.strokePath()
    let m = Mark.master
    let circle = CGPath(ellipseIn: CGRect(x: m.center.x - m.radius, y: m.center.y - m.radius, width: 2 * m.radius, height: 2 * m.radius), transform: nil)
    ctx.addPath(transformed(m.arc, ct)); ctx.setFillColor(rgb(Palette.graphite, 0.85)); ctx.fillPath()
    ctx.addPath(transformed(m.dotPath, ct)); ctx.setFillColor(rgb(Palette.tomato)); ctx.fillPath()
    ctx.addPath(transformed(circle, ct)); ctx.setStrokeColor(rgb(0x2F7DF6, 0.9)); ctx.setLineWidth(1.2); ctx.strokePath()
    text(ctx, "Construction", at: CGPoint(x: 250, y: 214), size: 13, weight: .semibold, color: ink)
    let notes = [String(format: "Ring r %.0f, band %.0f; dot %.1f on the same centre line", m.radius, m.weight, m.dot),
                 String(format: "Head: straight radial cut, %.1f clear of the dot", m.cut),
                 String(format: "Tail: round cap; mouth %.0f clear of the dot", m.mouth),
                 "Blue: the centre line both pieces share"]
    for (i, n) in notes.enumerated() { text(ctx, n, at: CGPoint(x: 250, y: 190 - CGFloat(i) * 20), size: 12) }

    // Colours.
    let swatches: [(String, UInt32, Bool)] = [("Tomato", Palette.tomato, true), ("Tile top", Look.dark.tile.0, true),
                                              ("Tile bottom", Look.dark.tile.1, true), ("Graphite", Palette.graphite, true),
                                              ("Silver", Palette.silver, false), ("Arc", Look.dark.arc.1, false), ("Paper", Look.light.tile.0, false)]
    x = 620
    for (name, hex, darkSwatch) in swatches {
        let r = CGRect(x: x, y: 60, width: 124, height: 170)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.setFillColor(rgb(hex)); ctx.fillPath()
        let c: UInt32 = darkSwatch ? 0xFFFFFF : ink
        text(ctx, name, at: CGPoint(x: x + 12, y: 90), size: 14, weight: .medium, color: c)
        text(ctx, String(format: "#%06X", hex), at: CGPoint(x: x + 12, y: 72), size: 12, color: c, mono: true)
        x += 132
    }
    return ctx.makeImage()!
}

// MARK: - Files

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Branding", isDirectory: true)
let fm = FileManager.default
let layers = out.appendingPathComponent("Chronato.icon/Assets", isDirectory: true)
try fm.createDirectory(at: layers, withIntermediateDirectories: true)

let iconset = fm.temporaryDirectory.appendingPathComponent("Chronato-\(UUID().uuidString).iconset", isDirectory: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        try writePNG(icon(points * factor), to: iconset.appendingPathComponent("icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

try writePNG(icon(1024), to: out.appendingPathComponent("logo-1024.png"))
try writePNG(icon(1024, fullBleed: true), to: out.appendingPathComponent("AppIcon-iOS-1024.png"))
try writePNG(drawBoard(), to: out.appendingPathComponent("brand-board.png"))
try markSVG.write(to: out.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)
try logoSVG.write(to: out.appendingPathComponent("logo.svg"), atomically: true, encoding: .utf8)
try layerSVG("<path d=\"\(svgPath(Mark.master.arc, scale: 16))\" fill=\"#FFFFFF\"/>")
    .write(to: layers.appendingPathComponent("arc.svg"), atomically: true, encoding: .utf8)
try layerSVG(svgDot(16, fill: "#E5533D")).write(to: layers.appendingPathComponent("dot.svg"), atomically: true, encoding: .utf8)
print("✓ \(out.path): AppIcon.icns, logo-1024.png, AppIcon-iOS-1024.png, brand-board.png, mark.svg, logo.svg, Chronato.icon/Assets")
