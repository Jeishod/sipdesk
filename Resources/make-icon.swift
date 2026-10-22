import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Usage: make-icon.swift OUTPUT_DIRECTORY") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let shape = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 208, yRadius: 208)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.04, green: 0.50, blue: 0.43, alpha: 1),
                              ending: NSColor(srgbRed: 0.06, green: 0.20, blue: 0.24, alpha: 1))!
    gradient.draw(in: shape, angle: 70)
    let circle = NSBezierPath(ovalIn: NSRect(x: 196, y: 196, width: 632, height: 632))
    NSColor.white.withAlphaComponent(0.11).setStroke()
    circle.lineWidth = 2
    circle.stroke()
    if let symbol = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 440, weight: .semibold))?
        .withSymbolConfiguration(.init(paletteColors: [NSColor(srgbRed: 0.83, green: 1, blue: 0.94, alpha: 1)])) {
        symbol.draw(in: NSRect(x: 292, y: 285, width: 440, height: 450))
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(size: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try drawIcon(size: 1024).write(to: output.appendingPathComponent("icon-preview.png"))

