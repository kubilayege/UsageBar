// Draws the flat UsageBar app icon: three window meters on a graphite tile.
// Each meter is filled with usage, one carries a hatched projection, and a bone
// needle marks "now" across all three, the same marks the app draws in its meters.
//
//   swift scripts/render-app-icon.swift Sources/UsageBar/Resources/AppLogo.png
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppLogo.png"
let size = 1024
let canvas = CGFloat(size)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let tileColor = color(0x221E1D)
let trackColor = color(0x37322F)
let apricot = color(0xEBA27A)
let bone = color(0xEFE8E1)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// macOS icon grid: an 824-point tile centred on the 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
tileColor.setFill()
tilePath.fill()
// A hairline rim keeps the tile's edge visible on dark docks without adding depth.
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
color(0xFFFFFF, 0.07).setStroke()
let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
rim.lineWidth = 4
rim.stroke()
NSGraphicsContext.restoreGraphicsState()

// Three meters, bottoms aligned: medium, short, tallest, like the original emblem.
let barWidth: CGFloat = 132, gap: CGFloat = 58
let left = tile.midX - (barWidth * 3 + gap * 2) / 2
let bottom: CGFloat = 262, top: CGFloat = 762
let radius: CGFloat = 28
let fills: [CGFloat] = [0.68, 0.36, 0.84]
let projection: (index: Int, to: CGFloat) = (2, 1.0)
let needle: CGFloat = 0.52

for (i, fill) in fills.enumerated() {
    let x = left + CGFloat(i) * (barWidth + gap)
    let track = NSRect(x: x, y: bottom, width: barWidth, height: top - bottom)
    let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
    trackColor.setFill()
    trackPath.fill()

    NSGraphicsContext.saveGraphicsState()
    trackPath.addClip()
    if projection.index == i {
        let ghost = NSRect(x: x, y: bottom + track.height * fill, width: barWidth, height: track.height * (projection.to - fill))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: ghost).addClip()
        apricot.withAlphaComponent(0.16).setFill()
        NSBezierPath(rect: ghost).fill()
        let hatch = NSBezierPath()
        var offset = ghost.minX - ghost.height
        while offset < ghost.maxX {
            hatch.move(to: NSPoint(x: offset, y: ghost.minY))
            hatch.line(to: NSPoint(x: offset + ghost.height, y: ghost.maxY))
            offset += 30
        }
        hatch.lineWidth = 11
        apricot.withAlphaComponent(0.62).setStroke()
        hatch.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    apricot.setFill()
    NSBezierPath(rect: NSRect(x: x, y: bottom, width: barWidth, height: track.height * fill)).fill()
    NSGraphicsContext.restoreGraphicsState()
}

// The needle: a bone rule across every meter, cut out of the tile so it reads at 16 px.
let needleY = bottom + (top - bottom) * needle
let needleRect = NSRect(x: left - 28, y: needleY - 12, width: barWidth * 3 + gap * 2 + 56, height: 24)
tileColor.setFill()
NSBezierPath(roundedRect: needleRect.insetBy(dx: -10, dy: -10), xRadius: 22, yRadius: 22).fill()
bone.setFill()
NSBezierPath(roundedRect: needleRect, xRadius: 12, yRadius: 12).fill()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
