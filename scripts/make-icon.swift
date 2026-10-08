#!/usr/bin/env swift
// Draws Chronato's app icon with CoreGraphics.
//
//   swift scripts/make-icon.swift Branding
//
// Writes <dir>/AppIcon.icns (every iconset size, packed by iconutil),
// <dir>/logo-1024.png and <dir>/AppIcon-iOS-1024.png (full bleed, for the
// iPhone app: copy it to iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png).
// The mark, the "C-stopwatch", is defined once below on
// a 64-unit grid. Brand.menuBarGlyph (18 pt) and Branding/logo.svg are
// hand-tuned copies of the same geometry: change all three together.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - The mark (64-unit grid, y up)

enum Mark {
    static let center = CGPoint(x: 34, y: 28.5)
    /// Ring centre line and weight.
    static let radius: CGFloat = 18.5
    static let weight: CGFloat = 7.5
    /// Half the opening on the right, in degrees. The 280° arc plus its round
    /// caps shows as a ~300° ring that reads as a C.
    static let gap: CGFloat = 40
    /// The hand points to 2 o'clock, just above the opening.
    static let handAngle: CGFloat = 30
    static let handLength: CGFloat = 10.5
    static let handWidth: CGFloat = 4.0
    static let dotRadius: CGFloat = 3.9
    /// Crown: a narrow stem from the ring up to a wider button.
    static let stemWidth: CGFloat = 5
    static let buttonSize = CGSize(width: 15, height: 5.5)
    static let buttonGap: CGFloat = 2.6

    /// Ring + crown (silver) and hand + dot (tomato). `bold` thickens the
    /// strokes for the smallest icon sizes, where 1 px lines turn to mist.
    static func paths(bold: CGFloat = 1) -> (silver: CGPath, hand: CGPath) {
        let w = weight * bold
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: radius, startAngle: rad(gap), endAngle: rad(360 - gap), clockwise: false)
        let ring = arc.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)

        let ringTop = center.y + radius + w / 2
        let buttonY = ringTop + buttonGap
        let stem = CGPath(rect: CGRect(x: center.x - stemWidth * bold / 2, y: center.y + radius,
                                       width: stemWidth * bold, height: buttonY - center.y - radius + 0.5), transform: nil)
        let bh = buttonSize.height * min(bold, 1.15)
        let button = CGPath(roundedRect: CGRect(x: center.x - buttonSize.width / 2, y: buttonY, width: buttonSize.width, height: bh),
                            cornerWidth: bh * 0.4, cornerHeight: bh * 0.4, transform: nil)
        let silver = ring.union(stem).union(button)

        let tip = CGPoint(x: center.x + handLength * cos(rad(handAngle)), y: center.y + handLength * sin(rad(handAngle)))
        let line = CGMutablePath()
        line.move(to: center)
        line.addLine(to: tip)
        let hand = line.copy(strokingWithWidth: handWidth * bold, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let dot = CGPath(ellipseIn: CGRect(x: center.x - dotRadius * bold, y: center.y - dotRadius * bold,
                                           width: dotRadius * bold * 2, height: dotRadius * bold * 2), transform: nil)
        return (silver, hand.union(dot))
    }

    static func rad(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }
}

// MARK: - Icon (drawn in 1024 space, scaled to each size)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha])!
}

/// Rounded rectangle with continuous corners, the macOS app-icon shape. The
/// constants are the well-known approximation of Apple's corner curve: each
/// corner starts 1.5287 r from the vertex and eases into the arc.
func squircle(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let corner: [(CGFloat, CGFloat)] = [
        (1.08849323, 0), (0.86840689, 0), (0.66993427, 0.06245183),
        (0.63149399, 0.07491100),
        (0.37282392, 0.16905899), (0.16906013, 0.37282401), (0.07491100, 0.63149399),
        (0.06245183, 0.66993427),
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

struct Painter {
    let ctx: CGContext
    /// Pixels per 1024-space unit. Shadows ignore the CTM, so they are scaled by hand.
    let scale: CGFloat

    func dropShadow(_ path: CGPath, dy: CGFloat, blur: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: dy * scale), blur: blur * scale, color: color)
        ctx.addPath(path)
        ctx.setFillColor(rgb(0x000000))
        ctx.fillPath()
        ctx.restoreGState()
    }

    func gradient(_ path: CGPath, _ stops: [(UInt32, CGFloat)], from: CGPoint, to: CGPoint) {
        let g = CGGradient(colorsSpace: sRGB, colors: stops.map { rgb($0.0) } as CFArray, locations: stops.map(\.1))!
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    func glow(_ path: CGPath, at center: CGPoint, radius: CGFloat, color: CGColor) {
        let clear = color.copy(alpha: 0)!
        let g = CGGradient(colorsSpace: sRGB, colors: [color, clear] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    /// A soft light or dark band just inside `path`'s edge: the shadow of
    /// everything outside the path, shifted by `dy`, clipped to the path.
    /// dy < 0 lights the top edge; dy > 0 shades the bottom edge.
    func innerEdge(_ path: CGPath, dy: CGFloat, blur: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setShadow(offset: CGSize(width: 0, height: dy * scale), blur: blur * scale, color: color)
        let outside = CGMutablePath()
        outside.addRect(CGRect(x: -1024, y: -1024, width: 3072, height: 3072))
        outside.addPath(path)
        ctx.addPath(outside)
        ctx.setFillColor(rgb(0x000000))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }
}

/// `fullBleed`: the iOS icon. iOS cuts the corners itself, so the tile fills the
/// square without drop shadow or edge light, and the PNG has no alpha channel
/// (App Store Connect rejects one). The mark keeps its share of the tile.
func renderIcon(pixels: Int, fullBleed: Bool = false) -> CGImage {
    let alpha = fullBleed ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: alpha.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    ctx.interpolationQuality = .high
    let paint = Painter(ctx: ctx, scale: scale)

    // Tile: Big Sur grid, an 824 squircle centred on the 1024 canvas (macOS),
    // or the whole canvas (iOS). `k` scales tile-relative sizes; 1 on macOS.
    let rect = fullBleed ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : CGRect(x: 100, y: 100, width: 824, height: 824)
    let k = rect.width / 824
    let tile = fullBleed ? CGPath(rect: rect, transform: nil) : squircle(rect, radius: 185.4)
    if !fullBleed { paint.dropShadow(tile, dy: -10, blur: 24, color: rgb(0x000000, 0.42)) }
    paint.gradient(tile, [(0x3A3D42, 0), (0x26282C, 0.55), (0x1A1B1E, 1)], from: CGPoint(x: 512, y: rect.maxY), to: CGPoint(x: 512, y: rect.minY))
    // Broad upper-left softbox.
    paint.glow(tile, at: CGPoint(x: rect.minX + 200 * k, y: rect.minY + 760 * k), radius: 760 * k, color: rgb(0xFFFFFF, 0.075))
    if !fullBleed {
        paint.innerEdge(tile, dy: -2.5, blur: 2, color: rgb(0xFFFFFF, 0.16))
        paint.innerEdge(tile, dy: 3, blur: 4, color: rgb(0x000000, 0.45))
    }

    // Mark: the 64-unit grid scaled so the symbol covers ~58 % of the tile.
    let units: CGFloat = 10.6 * k
    let bold: CGFloat = pixels <= 16 ? 1.35 : pixels <= 32 ? 1.18 : 1
    var t = CGAffineTransform(translationX: 512 - 32 * units, y: 512 - 32 * units).scaledBy(x: units, y: units)
    let (s, h) = Mark.paths(bold: bold)
    let silver = s.copy(using: &t)!
    let hand = h.copy(using: &t)!
    let box = silver.boundingBoxOfPath

    // Satin silver: tight contact shadow, top-left key light, fine bevel.
    paint.dropShadow(silver, dy: -9, blur: 14, color: rgb(0x000000, 0.55))
    paint.gradient(silver, [(0xF4F5F7, 0), (0xD3D6DA, 0.38), (0xB4B8BE, 0.72), (0x8F949B, 1)],
                   from: CGPoint(x: box.minX, y: box.maxY), to: CGPoint(x: box.maxX, y: box.minY))
    paint.glow(silver, at: CGPoint(x: box.minX + box.width * 0.22, y: box.maxY - box.height * 0.18), radius: box.width * 0.55,
               color: rgb(0xFFFFFF, 0.35))
    paint.innerEdge(silver, dy: -2.5, blur: 2, color: rgb(0xFFFFFF, 0.85))
    paint.innerEdge(silver, dy: 3, blur: 3.5, color: rgb(0x2A2C30, 0.45))

    // Tomato hand, same light.
    let hb = hand.boundingBoxOfPath
    paint.dropShadow(hand, dy: -6, blur: 10, color: rgb(0x000000, 0.55))
    paint.gradient(hand, [(0xF57A63, 0), (0xE5533D, 0.5), (0xC4412D, 1)],
                   from: CGPoint(x: hb.minX, y: hb.maxY), to: CGPoint(x: hb.maxX, y: hb.minY))
    paint.innerEdge(hand, dy: -2, blur: 2, color: rgb(0xFFFFFF, 0.5))
    paint.innerEdge(hand, dy: 2.5, blur: 3, color: rgb(0x5A1A10, 0.45))

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
try fm.createDirectory(at: out, withIntermediateDirectories: true)
let iconset = fm.temporaryDirectory.appendingPathComponent("Chronato-\(UUID().uuidString).iconset", isDirectory: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

var rendered: [Int: CGImage] = [:]
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = points * factor
        let image = rendered[pixels] ?? renderIcon(pixels: pixels)
        rendered[pixels] = image
        try writePNG(image, to: iconset.appendingPathComponent("icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"))
    }
}
try writePNG(rendered[1024]!, to: out.appendingPathComponent("logo-1024.png"))
try writePNG(renderIcon(pixels: 1024, fullBleed: true), to: out.appendingPathComponent("AppIcon-iOS-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("✓ \(out.path)/AppIcon.icns, logo-1024.png, AppIcon-iOS-1024.png")
