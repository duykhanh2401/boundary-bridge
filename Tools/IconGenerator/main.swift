import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(calibratedRed: 0.05, green: 0.18, blue: 0.22, alpha: 1),
                   ending: NSColor(calibratedRed: 0.02, green: 0.43, blue: 0.43, alpha: 1))!.draw(in: background, angle: 45)
        let bridge = NSBezierPath()
        bridge.move(to: NSPoint(x: 275, y: 335))
        bridge.line(to: NSPoint(x: 275, y: 635))
        bridge.curve(to: NSPoint(x: 749, y: 635), controlPoint1: NSPoint(x: 370, y: 780), controlPoint2: NSPoint(x: 654, y: 780))
        bridge.line(to: NSPoint(x: 749, y: 335))
        bridge.lineWidth = 65
        bridge.lineCapStyle = .round
        NSColor(calibratedRed: 0.57, green: 0.96, blue: 0.84, alpha: 1).setStroke()
        bridge.stroke()
        let road = NSBezierPath()
        road.move(to: NSPoint(x: 210, y: 425)); road.line(to: NSPoint(x: 814, y: 425))
        road.lineWidth = 54; road.lineCapStyle = .round
        NSColor.white.setStroke(); road.stroke()
        for x in [275, 749] {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 58, y: 277, width: 116, height: 116)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
