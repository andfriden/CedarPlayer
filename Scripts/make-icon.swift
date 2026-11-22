// Cedar Player icon generation: 1024 px PNG + .iconset + .icns.
// Run: swift Scripts/make-icon.swift Resources/AppIcon
import AppKit
import Foundation

let outputBase = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon"
let side: CGFloat = 1024
let canvas = NSRect(x: 0, y: 0, width: side, height: side)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(side),
                                 pixelsHigh: Int(side),
                                 bitsPerSample: 8,
                                 samplesPerPixel: 4,
                                 hasAlpha: true,
                                 isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0,
                                 bitsPerPixel: 0) else {
    fatalError("нет буфера")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
NSGraphicsContext.current?.shouldAntialias = true

// Background: a rounded square with a soft gradient.
let background = NSBezierPath(roundedRect: canvas, xRadius: 228, yRadius: 228)
NSGradient(colors: [NSColor(srgbRed: 0.11, green: 0.15, blue: 0.21, alpha: 1),
                    NSColor(srgbRed: 0.06, green: 0.08, blue: 0.11, alpha: 1)])?
    .draw(in: background, angle: -90)

// Glow under the crown.
NSGraphicsContext.saveGraphicsState()
NSBezierPath(ovalIn: NSRect(x: 192, y: 300, width: 640, height: 640)).addClip()
NSGradient(colors: [NSColor(srgbRed: 0.48, green: 0.65, blue: 1.0, alpha: 0.20),
                    NSColor(srgbRed: 0.48, green: 0.65, blue: 1.0, alpha: 0.0)])?
    .draw(in: NSRect(x: 192, y: 300, width: 640, height: 640), relativeCenterPosition: .zero)
NSGraphicsContext.restoreGraphicsState()

func treeLayer(apexY: CGFloat, baseY: CGFloat, halfWidth: CGFloat,
               top: NSColor, bottom: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: side / 2, y: apexY))
    path.line(to: NSPoint(x: side / 2 - halfWidth, y: baseY))
    path.line(to: NSPoint(x: side / 2 + halfWidth, y: baseY))
    path.close()
    path.lineJoinStyle = .round
    path.lineWidth = 26

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: top, ending: bottom)?.draw(in: NSRect(x: 0, y: baseY,
                                                              width: side, height: apexY - baseY),
                                                    angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.10).setStroke()
    path.stroke()
}

treeLayer(apexY: 892, baseY: 626, halfWidth: 150,
          top: NSColor(srgbRed: 0.72, green: 0.83, blue: 1.0, alpha: 1),
          bottom: NSColor(srgbRed: 0.52, green: 0.67, blue: 0.95, alpha: 1))
treeLayer(apexY: 792, baseY: 486, halfWidth: 208,
          top: NSColor(srgbRed: 0.64, green: 0.78, blue: 1.0, alpha: 1),
          bottom: NSColor(srgbRed: 0.42, green: 0.58, blue: 0.90, alpha: 1))
treeLayer(apexY: 676, baseY: 330, halfWidth: 262,
          top: NSColor(srgbRed: 0.57, green: 0.72, blue: 1.0, alpha: 1),
          bottom: NSColor(srgbRed: 0.32, green: 0.47, blue: 0.80, alpha: 1))

// Trunk.
let trunk = NSBezierPath(roundedRect: NSRect(x: side / 2 - 40, y: 236, width: 80, height: 118),
                         xRadius: 22, yRadius: 22)
NSGradient(starting: NSColor(srgbRed: 0.66, green: 0.73, blue: 0.85, alpha: 1),
           ending: NSColor(srgbRed: 0.40, green: 0.48, blue: 0.62, alpha: 1))?
    .draw(in: trunk, angle: -90)

// Play glyph.
let badge = NSRect(x: side - 330, y: 190, width: 236, height: 236)
let badgePath = NSBezierPath(ovalIn: badge)
NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1).setFill()
badgePath.fill()

let play = NSBezierPath()
let cx = badge.midX + 12, cy = badge.midY
play.move(to: NSPoint(x: cx - 34, y: cy + 52))
play.line(to: NSPoint(x: cx - 34, y: cy - 52))
play.line(to: NSPoint(x: cx + 52, y: cy))
play.close()
play.lineJoinStyle = .round
play.lineWidth = 16
NSColor(srgbRed: 0.09, green: 0.12, blue: 0.17, alpha: 1).setFill()
play.fill()

// Thin inner border.
NSColor.white.withAlphaComponent(0.07).setStroke()
background.lineWidth = 4
background.stroke()

NSGraphicsContext.restoreGraphicsState()

let fm = FileManager.default
let directory = (outputBase as NSString).deletingLastPathComponent
if !directory.isEmpty { try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true) }
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputBase + "-1024.png"))

let iconset = outputBase + ".iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (pixels, name) in variants {
    let scaled = NSImage(size: NSSize(width: pixels, height: pixels))
    scaled.lockFocus()
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    scaled.unlockFocus()
    if let tiff = scaled.tiffRepresentation,
       let scaledRep = NSBitmapImageRep(data: tiff),
       let png = scaledRep.representation(using: .png, properties: [:]) {
        try! png.write(to: URL(fileURLWithPath: iconset + "/" + name))
    }
}
print("iconset: \(iconset)")
