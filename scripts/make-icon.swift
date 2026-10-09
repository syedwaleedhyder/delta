// Draws the Delta app icon (a Δ over a red/green split) and writes AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift Sources/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: the rounded square fills ~80% of the canvas.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225
    let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.set()
    NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Left half red, right half green: the two sides of a diff.
    path.addClip()
    NSColor(calibratedRed: 0.86, green: 0.25, blue: 0.27, alpha: 0.9).setFill()
    NSRect(x: tile.minX, y: tile.minY, width: tile.width / 2, height: tile.height).fill()
    NSColor(calibratedRed: 0.18, green: 0.68, blue: 0.36, alpha: 0.9).setFill()
    NSRect(x: tile.midX, y: tile.minY, width: tile.width / 2, height: tile.height).fill()

    // Δ outline in white.
    let w = tile.width * 0.56
    let h = w * 0.9
    let cx = tile.midX
    let base = tile.midY - h * 0.45
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: cx - w / 2, y: base))
    triangle.line(to: NSPoint(x: cx + w / 2, y: base))
    triangle.line(to: NSPoint(x: cx, y: base + h))
    triangle.close()
    triangle.lineWidth = tile.width * 0.075
    triangle.lineJoinStyle = .round
    NSColor.white.setStroke()
    triangle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(size: points * scale).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))
