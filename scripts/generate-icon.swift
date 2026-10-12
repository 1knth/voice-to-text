import AppKit
import Foundation

// First-party icon exporter: only Apple frameworks, no asset packages or downloads.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let sizes = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
             (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
             (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
for (size, name) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 512, y: CGFloat(size) / 512)
    let tile = NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 480, height: 480), xRadius: 108, yRadius: 108)
    NSGradient(starting: NSColor(calibratedRed: 0.38, green: 0.71, blue: 1, alpha: 1),
               ending: NSColor(calibratedRed: 0.09, green: 0.29, blue: 0.77, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.22).setStroke(); tile.lineWidth = 2; tile.stroke()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 215, y: 216, width: 82, height: 170), xRadius: 41, yRadius: 41).fill()
    NSColor.white.setStroke()
    let cradle = NSBezierPath(); cradle.lineWidth = 18; cradle.lineCapStyle = .round; cradle.lineJoinStyle = .round
    cradle.move(to: NSPoint(x: 184, y: 254)); cradle.line(to: NSPoint(x: 184, y: 238))
    cradle.curve(to: NSPoint(x: 328, y: 238), controlPoint1: NSPoint(x: 184, y: 142), controlPoint2: NSPoint(x: 328, y: 142))
    cradle.line(to: NSPoint(x: 328, y: 254)); cradle.stroke()
    let stand = NSBezierPath(); stand.lineWidth = 18; stand.lineCapStyle = .round
    stand.move(to: NSPoint(x: 256, y: 165)); stand.line(to: NSPoint(x: 256, y: 126))
    stand.move(to: NSPoint(x: 221, y: 126)); stand.line(to: NSPoint(x: 291, y: 126)); stand.stroke()
    for (x, length, width, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) in [
        (154, 43, 14, 0.9), (358, 43, 14, 0.9), (122, 21, 12, 0.65), (390, 21, 12, 0.65)
    ] {
        NSColor.white.withAlphaComponent(alpha).setStroke()
        let wave = NSBezierPath(); wave.lineWidth = width; wave.lineCapStyle = .round
        wave.move(to: NSPoint(x: x, y: 282.5 - length / 2)); wave.line(to: NSPoint(x: x, y: 282.5 + length / 2)); wave.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("icon_\(name).png"))
}
