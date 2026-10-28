// Renders the ClipStack app icon into an .iconset folder.
// Usage: swift make_icon.swift <output.iconset> && iconutil -c icns <output.iconset> -o AppIcon.icns
//        swift make_icon.swift --ios <output.png>   (1024px full-bleed square; iOS rounds the corners)
import AppKit

let ios = CommandLine.arguments[1] == "--ios"
let out = CommandLine.arguments.last!
if !ios { try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true) }

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // Rounded-square background with a teal→green gradient.
    let bg = ios ? NSRect(x: 0, y: 0, width: 1024 * s, height: 1024 * s)
                 : NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = ios ? NSBezierPath(rect: bg) : NSBezierPath(roundedRect: bg, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.05, green: 0.62, blue: 0.72, alpha: 1),
                        NSColor(red: 0.18, green: 0.80, blue: 0.52, alpha: 1)])!.draw(in: squircle, angle: -60)

    // Three stacked history cards, back to front.
    let cards: [(CGFloat, CGFloat)] = [(0.30, 150), (0.55, 75), (1.0, 0)]
    for (alpha, offset) in cards {
        NSGraphicsContext.saveGraphicsState()
        if alpha == 1 {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 30 * s
            shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
            shadow.set()
        }
        let rect = NSRect(x: (262 + offset * 0.4) * s, y: (250 + offset) * s,
                          width: (500 - offset * 0.8) * s, height: 340 * s)
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 44 * s, yRadius: 44 * s).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Text lines on the front card.
    let lineColor = NSColor(red: 0.05, green: 0.55, blue: 0.62, alpha: 1)
    lineColor.setFill()
    for (i, width) in [CGFloat(330), 380, 250].enumerated() {
        let y = (500 - CGFloat(i) * 70) * s
        NSBezierPath(roundedRect: NSRect(x: 322 * s, y: y, width: width * s, height: 34 * s),
                     xRadius: 17 * s, yRadius: 17 * s).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if ios {
    try! render(1024).write(to: URL(fileURLWithPath: out))
    exit(0)
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
