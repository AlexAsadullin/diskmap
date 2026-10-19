// Draws the app icon (a small treemap) as a 1024×1024 PNG.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// macOS icon grid: 824 px rounded square centred in 1024.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setFillColor(color(0x1B1C1F))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0)

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
let inner = tile.insetBy(dx: 70, dy: 70)
let W = inner.width, H = inner.height
// Rectangles in a 0…1 unit square (origin top-left), coloured like the app's categories.
let blocks: [(CGFloat, CGFloat, CGFloat, CGFloat, UInt32)] = [
    (0, 0, 0.56, 0.62, 0x3E63DD),      // Movies
    (0.56, 0, 0.44, 0.36, 0xE5484D),   // Applications
    (0.56, 0.36, 0.24, 0.26, 0xFFC53D),// Library
    (0.80, 0.36, 0.20, 0.26, 0x30A46C),// Documents
    (0, 0.62, 0.34, 0.38, 0xD6409F),   // Pictures
    (0.34, 0.62, 0.30, 0.38, 0x7CB518),// Development
    (0.64, 0.62, 0.36, 0.20, 0xF76B15),// Downloads
    (0.64, 0.82, 0.18, 0.18, 0x8E4EC6),// Music
    (0.82, 0.82, 0.18, 0.18, 0x0090FF),// iCloud
]
let gap: CGFloat = 14
for (x, y, w, h, hex) in blocks {
    let r = CGRect(x: inner.minX + x * W, y: inner.maxY - (y + h) * H, width: w * W, height: h * H).insetBy(dx: gap / 2, dy: gap / 2)
    let c = color(hex)
    let light = c.copy(alpha: 1)!
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(cgColor: light)!.blended(withFraction: 0.30, of: .white)!.cgColor, light,
        NSColor(cgColor: light)!.blended(withFraction: 0.25, of: .black)!.cgColor] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
    ctx.restoreGState()
}
ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
