#!/usr/bin/env swift
// Draws Notch's app icon and writes every size macOS needs into the asset catalog.
// Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("Notch/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Draws the icon on a 1024 × 1024 canvas (origin bottom-left).
func drawIcon(in ctx: CGContext) {
    // macOS icon grid: an 824 pt rounded tile centred on the canvas, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    color(0x141826).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Wallpaper: the same dusk gradient as the design prototype.
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(colors: [color(0x1b2340), color(0x141826), color(0x2a1f2a)], atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
        .draw(in: tilePath, angle: -70)
    let glows: [(CGPoint, CGFloat, NSColor)] = [
        (CGPoint(x: 180, y: 120), 620, color(0xd98b4a, 0.85)),
        (CGPoint(x: 900, y: 940), 560, color(0x2f8c8a, 0.8)),
        (CGPoint(x: 560, y: 420), 480, color(0x3b3f78, 0.7)),
    ]
    for (center, radius, c) in glows {
        NSGradient(colors: [c, c.withAlphaComponent(0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }

    // Menu bar.
    let menuBar = CGRect(x: tile.minX, y: tile.maxY - 74, width: tile.width, height: 74)
    color(0x0a0c14, 0.32).setFill()
    menuBar.fill()

    // The island, hanging from the top edge, with the artwork glow beneath it.
    let island = CGRect(x: 512 - 280, y: tile.maxY - 196, width: 560, height: 196)
    let islandPath = NSBezierPath()
    let r: CGFloat = 92
    islandPath.move(to: CGPoint(x: island.minX - 22, y: island.maxY))
    islandPath.appendArc(withCenter: CGPoint(x: island.minX - 22, y: island.maxY - 22), radius: 22, startAngle: 90, endAngle: 0, clockwise: true)
    islandPath.line(to: CGPoint(x: island.minX, y: island.minY + r))
    islandPath.appendArc(withCenter: CGPoint(x: island.minX + r, y: island.minY + r), radius: r, startAngle: 180, endAngle: 270)
    islandPath.line(to: CGPoint(x: island.maxX - r, y: island.minY))
    islandPath.appendArc(withCenter: CGPoint(x: island.maxX - r, y: island.minY + r), radius: r, startAngle: 270, endAngle: 360)
    islandPath.line(to: CGPoint(x: island.maxX, y: island.maxY - 22))
    islandPath.appendArc(withCenter: CGPoint(x: island.maxX + 22, y: island.maxY - 22), radius: 22, startAngle: 180, endAngle: 90, clockwise: true)
    islandPath.close()

    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0xff8a6b, 0.75)
    glow.shadowBlurRadius = 70
    glow.shadowOffset = NSSize(width: 0, height: -26)
    glow.set()
    NSColor.black.setFill()
    islandPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.black.setFill()
    islandPath.fill()

    // Inside the island: album art on the left, the waveform on the right.
    let art = CGRect(x: island.minX + 58, y: island.minY + 44, width: 92, height: 92)
    let artPath = NSBezierPath(roundedRect: art, xRadius: 22, yRadius: 22)
    NSGradient(colors: [color(0xff7a59), color(0xc43d7a), color(0x3b2a6b)])!.draw(in: artPath, angle: -45)
    color(0xffd27a).setFill()
    NSBezierPath(ovalIn: CGRect(x: art.minX + 16, y: art.maxY - 42, width: 26, height: 26)).fill()

    let heights: [CGFloat] = [0.45, 0.85, 0.6, 1.0, 0.5]
    let barWidth: CGFloat = 16, gap: CGFloat = 12, maxHeight: CGFloat = 96
    var x = island.maxX - 58 - (barWidth * 5 + gap * 4)
    for h in heights {
        let height = maxHeight * h
        let bar = CGRect(x: x, y: art.midY - height / 2, width: barWidth, height: height)
        color(0xff8a6b).setFill()
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    _ = ctx
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon(in: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
let catalog = output.deletingLastPathComponent().appendingPathComponent("Contents.json")
if !FileManager.default.fileExists(atPath: catalog.path) {
    try #"{"info":{"author":"xcode","version":1}}"#.write(to: catalog, atomically: true, encoding: .utf8)
}
print("Wrote \(images.count) icon sizes to \(output.path)")
