#!/usr/bin/env swift
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift /path/AppIcon.iconset\n", stderr)
    exit(2)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func round(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func display(_ rect: NSRect, bezel: NSColor, top: NSColor, bottom: NSColor) {
    round(NSRect(x: rect.midX - 22, y: rect.minY - 60, width: 44, height: 70), radius: 10, fill: bezel)
    round(NSRect(x: rect.midX - 100, y: rect.minY - 66, width: 200, height: 22), radius: 11, fill: bezel)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, alpha: 0.38)
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.shadowBlurRadius = 25
    shadow.set()
    round(rect, radius: 34, fill: bezel)
    NSGraphicsContext.restoreGraphicsState()
    let screen = NSBezierPath(roundedRect: rect.insetBy(dx: 15, dy: 15), xRadius: 21, yRadius: 21)
    NSGradient(starting: bottom, ending: top)!.draw(in: screen, angle: 65)
}

func drawIcon(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                  bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.imageInterpolation = .high

    let silhouette = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x050812, alpha: 0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -13)
    shadow.shadowBlurRadius = 26
    shadow.set()
    color(0x182333).setFill()
    silhouette.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x101620), ending: color(0x35465C))!.draw(in: silhouette, angle: 70)
    color(0xFFFFFF, alpha: 0.10).setStroke()
    silhouette.lineWidth = 3
    silhouette.stroke()

    display(NSRect(x: 357, y: 468, width: 465, height: 302), bezel: color(0xAABACA),
            top: color(0xB8DDD6), bottom: color(0x367A86))
    display(NSRect(x: 187, y: 319, width: 483, height: 321), bezel: color(0xE0E7EC),
            top: color(0x7398E9), bottom: color(0x253963))

    // A single crossing arrow reads as switching even at small Dock sizes.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 310, y: 466))
    arrow.line(to: NSPoint(x: 524, y: 466))
    arrow.move(to: NSPoint(x: 463, y: 522))
    arrow.line(to: NSPoint(x: 524, y: 466))
    arrow.line(to: NSPoint(x: 463, y: 410))
    arrow.lineWidth = 27
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    color(0xFFFFFF).setStroke()
    arrow.stroke()

    NSGraphicsContext.saveGraphicsState()
    let keyShadow = NSShadow()
    keyShadow.shadowColor = color(0x000000, alpha: 0.45)
    keyShadow.shadowOffset = NSSize(width: 0, height: -12)
    keyShadow.shadowBlurRadius = 24
    keyShadow.set()
    round(NSRect(x: 550, y: 171, width: 289, height: 223), radius: 52, fill: color(0x8C1927))
    NSGraphicsContext.restoreGraphicsState()
    let keyFace = NSBezierPath(roundedRect: NSRect(x: 550, y: 191, width: 289, height: 214), xRadius: 51, yRadius: 51)
    NSGradient(starting: color(0xDD3343), ending: color(0xFF6D6D))!.draw(in: keyFace, angle: 80)
    color(0xFFFFFF, alpha: 0.20).setStroke()
    keyFace.lineWidth = 3
    keyFace.stroke()

    let text = NSAttributedString(string: "PgDn", attributes: [
        .font: NSFont.systemFont(ofSize: 65, weight: .bold),
        .foregroundColor: color(0xFFFFFF),
        .kern: -2
    ])
    let textSize = text.size()
    text.draw(at: NSPoint(x: 694.5 - textSize.width / 2, y: 294 - textSize.height / 2))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix).png"
        try drawIcon(size: points * scale).write(to: destination.appendingPathComponent(name))
    }
}
