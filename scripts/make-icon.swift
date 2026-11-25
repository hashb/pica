// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.25, alpha: 1),
                        NSColor(calibratedRed: 0.85, green: 0.18, blue: 0.48, alpha: 1),
                        NSColor(calibratedRed: 0.35, green: 0.25, blue: 0.85, alpha: 1)])!
        .draw(in: path, angle: -60)
    // Stacked "photos"
    for (i, angle) in [(0, -10.0), (1, 6.0)] {
        let w = rect.width * 0.56, h = w * 0.76
        let frame = NSRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let t = NSAffineTransform()
        t.translateX(by: rect.midX + (i == 0 ? -size * 0.03 : size * 0.03), yBy: rect.midY + (i == 0 ? -size * 0.02 : size * 0.03))
        t.rotate(byDegrees: angle)
        NSGraphicsContext.saveGraphicsState()
        t.concat()
        let shadow = NSShadow(); shadow.shadowBlurRadius = size * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: frame, xRadius: size * 0.02, yRadius: size * 0.02).fill()
        if i == 1 {
            let innerFrame = frame.insetBy(dx: w * 0.07, dy: w * 0.07)
            NSGradient(colors: [NSColor(calibratedRed: 0.45, green: 0.75, blue: 1, alpha: 1), NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.9, alpha: 1)])!
                .draw(in: NSBezierPath(rect: innerFrame), angle: -90)
            let m = NSBezierPath()
            m.move(to: NSPoint(x: innerFrame.minX, y: innerFrame.minY))
            m.line(to: NSPoint(x: innerFrame.minX + innerFrame.width * 0.35, y: innerFrame.minY + innerFrame.height * 0.6))
            m.line(to: NSPoint(x: innerFrame.minX + innerFrame.width * 0.6, y: innerFrame.minY + innerFrame.height * 0.3))
            m.line(to: NSPoint(x: innerFrame.minX + innerFrame.width * 0.78, y: innerFrame.minY + innerFrame.height * 0.5))
            m.line(to: NSPoint(x: innerFrame.maxX, y: innerFrame.minY))
            m.close()
            NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.3, alpha: 1).setFill(); m.fill()
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.3, alpha: 1).setFill()
            let r = innerFrame.width * 0.09
            NSBezierPath(ovalIn: NSRect(x: innerFrame.maxX - r * 3, y: innerFrame.maxY - r * 3, width: r * 2, height: r * 2)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    try! render(CGFloat(s)).write(to: iconset.appendingPathComponent("icon_\(s)x\(s).png"))
    try! render(CGFloat(s * 2)).write(to: iconset.appendingPathComponent("icon_\(s)x\(s)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
