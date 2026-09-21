import AppKit

// Reproducible vector artwork: a selected photograph with a curator sparkle.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 196, yRadius: 196)
        NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.59, blue: 0.65, alpha: 1),
                   ending: NSColor(srgbRed: 0.03, green: 0.22, blue: 0.40, alpha: 1))!.draw(in: tile, angle: -90)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 225, y: 275, width: 574, height: 478), xRadius: 48, yRadius: 48).fill()
        NSColor(srgbRed: 0.83, green: 0.94, blue: 0.96, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 265, y: 350, width: 494, height: 363)).fill()
        NSColor(srgbRed: 1, green: 0.69, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 602, y: 565, width: 90, height: 90)).fill()
        NSColor(srgbRed: 0.10, green: 0.49, blue: 0.50, alpha: 1).setFill()
        let mountain = NSBezierPath()
        mountain.move(to: NSPoint(x: 265, y: 350))
        for point in [NSPoint(x: 433, y: 592), NSPoint(x: 548, y: 440), NSPoint(x: 627, y: 526), NSPoint(x: 759, y: 350)] { mountain.line(to: point) }
        mountain.close(); mountain.fill()
        NSColor(srgbRed: 1, green: 0.76, blue: 0.30, alpha: 1).setFill()
        let sparkle = NSBezierPath()
        sparkle.move(to: NSPoint(x: 512, y: 335))
        for point in [NSPoint(x: 548, y: 241), NSPoint(x: 642, y: 205), NSPoint(x: 548, y: 169),
                      NSPoint(x: 512, y: 75), NSPoint(x: 476, y: 169), NSPoint(x: 382, y: 205), NSPoint(x: 476, y: 241)] {
            sparkle.line(to: point)
        }
        sparkle.close(); sparkle.fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
