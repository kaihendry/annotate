// Rebuild the app icon with Apple's tools only: make icon
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                  pixelsHigh: pixels, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)

    // A dark tile makes the same red / white annotation treatment used by the
    // app readable on both light and dark desktops, even at small Dock sizes.
    let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
                            xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x152039).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x2E3D58), ending: color(0x10182B))!
        .draw(in: tile, angle: 90)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    // A screenshot card, a highlighted region, and an unmistakable pointer.
    let card = NSBezierPath(roundedRect: NSRect(x: 222, y: 252, width: 580, height: 430),
                            xRadius: 36, yRadius: 36)
    color(0xF7F9FD).setFill()
    card.fill()
    color(0xD7DEEB).setFill()
    NSBezierPath(roundedRect: NSRect(x: 280, y: 312, width: 294, height: 24),
                 xRadius: 12, yRadius: 12).fill()
    NSBezierPath(roundedRect: NSRect(x: 280, y: 355, width: 174, height: 18),
                 xRadius: 9, yRadius: 9).fill()

    let highlight = NSBezierPath(roundedRect: NSRect(x: 282, y: 410, width: 284, height: 190),
                                 xRadius: 12, yRadius: 12)
    color(0xFF4B36).setStroke()
    highlight.lineWidth = 28
    highlight.stroke()

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 760, y: 758))
    arrow.line(to: NSPoint(x: 480, y: 478))
    arrow.move(to: NSPoint(x: 486, y: 624))
    arrow.line(to: NSPoint(x: 480, y: 478))
    arrow.line(to: NSPoint(x: 626, y: 484))
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor.white.setStroke()
    arrow.lineWidth = 100
    arrow.stroke()
    color(0xFF4B36).setStroke()
    arrow.lineWidth = 64
    arrow.stroke()
    return bitmap
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources",
                 isDirectory: true)
let files = FileManager.default
try files.createDirectory(at: output, withIntermediateDirectories: true)
let temporary = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let iconset = temporary.appendingPathComponent("Annotate.iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? files.removeItem(at: temporary) }

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let bitmap = drawIcon(pixels: size * scale)
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        if size * scale == 1024 {
            try data.write(to: output.appendingPathComponent("Annotate.png"))
        }
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o",
                      output.appendingPathComponent("Annotate.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Created \(output.path)/Annotate.icns and Annotate.png")
