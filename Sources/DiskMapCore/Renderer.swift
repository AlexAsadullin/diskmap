import Foundation
import CoreGraphics
import CoreText

public struct RGB: Equatable {
    public var r: CGFloat, g: CGFloat, b: CGFloat

    public init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }

    public init(hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }

    public var hex: UInt32 {
        func c(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return c(r) << 16 | c(g) << 8 | c(b)
    }

    public func mix(_ o: RGB, _ t: CGFloat) -> RGB {
        RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }

    public var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    public var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    public static let white = RGB(r: 1, g: 1, b: 1)
    public static let black = RGB(r: 0, g: 0, b: 0)
}

public struct RenderStyle {
    public var dark: Bool
    public var palette: [RGB]
    public var hidden: Set<UInt8> = []
    public var highlight: UInt8?
    /// When non-nil, everything outside these nodes (and their ancestors) is dimmed.
    public var matches: Set<ObjectIdentifier>?
    public var matchAncestors: Set<ObjectIdentifier> = []
    public var mode: SizeMode = .physical
    public var labels = true

    public init(dark: Bool, palette: [RGB]) {
        self.dark = dark
        self.palette = palette
    }

    public var background: RGB { dark ? RGB(hex: 0x1B1C1F) : RGB(hex: 0xF4F5F7) }
}

/// Draws laid-out items with Core Graphics. The context must use top-left origin coordinates.
public enum MapRenderer {
    public static let smallBlockColor = RGB(hex: 0x8B8D98)
    public static let noAccessColor = RGB(hex: 0x6F7178)

    /// Renders into a new bitmap of `size` points at `scale` pixels per point.
    public static func render(_ items: [LayoutItem], size: CGSize, scale: CGFloat, style: RenderStyle) -> CGImage? {
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(items, in: ctx, size: size, style: style)
        return ctx.makeImage()
    }

    public static func draw(_ items: [LayoutItem], in ctx: CGContext, size: CGSize, style: RenderStyle) {
        let bg = style.background
        ctx.setFillColor(bg.cg)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none

        var gradients: [Int: CGGradient] = [:]
        func gradient(_ c: RGB) -> CGGradient {
            let key = Int(c.hex)
            if let g = gradients[key] { return g }
            let light = c.mix(.white, 0.28), dark = c.mix(.black, 0.22)
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [light.cg, c.cg, dark.cg] as CFArray, locations: [0, 0.45, 1])!
            gradients[key] = g
            return g
        }

        // Search: an item is lit when it, or a folder above it, matches.
        var lit = [Bool](repeating: true, count: style.matches == nil ? 0 : items.count)
        if let matches = style.matches {
            for i in items.indices {
                let it = items[i]
                let id = ObjectIdentifier(it.node)
                lit[i] = (it.kind != .small && matches.contains(id))
                    || (it.parent >= 0 && lit[Int(it.parent)])
                    || (it.kind == .collapsed && style.matchAncestors.contains(id))
            }
        }

        let font = CTFontCreateUIFontForLanguage(.system, 10.5, nil)!
        let bold = CTFontCreateUIFontForLanguage(.emphasizedSystem, 10.5, nil)!
        var labels: [(title: String, sub: String?, rect: CGRect, fill: RGB, strong: Bool, header: Bool)] = []

        for i in items.indices {
            let it = items[i]
            let r = it.rect
            var dim = false
            if let h = style.highlight, it.kind != .folder, it.category != h { dim = true }
            if style.matches != nil && !lit[i] && it.kind != .folder { dim = true }
            let catColor = Int(it.category) < style.palette.count ? style.palette[Int(it.category)] : smallBlockColor
            func dimmed(_ c: RGB) -> RGB { dim ? c.mix(bg, 0.78) : c }

            switch it.kind {
            case .folder:
                let fill = catColor.mix(bg, style.dark ? 0.82 : 0.86)
                ctx.setFillColor(fill.cg)
                ctx.fill(r)
                if it.headerHeight > 0 {
                    let hr = CGRect(x: r.minX, y: r.minY, width: r.width, height: it.headerHeight + style.headerInset)
                    ctx.setFillColor(catColor.mix(bg, style.dark ? 0.55 : 0.6).cg)
                    ctx.fill(hr)
                    if style.labels && hr.width > 40 {
                        let title = it.node.displayName
                        labels.append((title, Fmt.bytes(it.node.size(style.mode)), hr.insetBy(dx: 4, dy: 1.5), catColor.mix(bg, 0.6), true, true))
                    }
                }
                let border = max(0.5, 2.4 - 0.45 * CGFloat(it.depth - 1))
                ctx.setStrokeColor(catColor.mix(style.dark ? .black : RGB(hex: 0x3A3D44), 0.45).cg)
                ctx.setLineWidth(border)
                ctx.stroke(r.insetBy(dx: border / 2, dy: border / 2))

            case .file, .collapsed:
                if style.hidden.contains(it.category) { continue }
                var c = dimmed(catColor)
                if it.node.flags.contains(.dataless) { c = c.mix(bg, 0.5) }
                let fr = r.width >= 3 && r.height >= 3 ? r.insetBy(dx: 0.5, dy: 0.5) : r
                if fr.width >= 5 && fr.height >= 5 {
                    ctx.saveGState()
                    ctx.clip(to: fr)
                    ctx.drawLinearGradient(gradient(c), start: CGPoint(x: fr.minX, y: fr.minY), end: CGPoint(x: fr.maxX, y: fr.maxY), options: [])
                    ctx.restoreGState()
                } else {
                    ctx.setFillColor(c.cg)
                    ctx.fill(fr)
                }
                if it.kind == .collapsed && r.width >= 6 && r.height >= 6 {
                    ctx.setStrokeColor(c.mix(.black, 0.45).cg)
                    ctx.setLineWidth(1)
                    ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
                }
                if style.labels && r.width >= 80 && r.height >= 24 {
                    var name = it.node.displayName
                    if it.node.flags.contains(.dataless) { name += " ☁︎" }
                    labels.append((name, Fmt.bytes(it.node.size(style.mode)), r.insetBy(dx: 4, dy: 3), c, it.kind == .collapsed, false))
                }

            case .small:
                let c = dimmed(smallBlockColor.mix(bg, 0.35))
                ctx.setFillColor(c.cg)
                ctx.fill(r)
                if style.labels && r.width >= 80 && r.height >= 24 {
                    let title = T("Мелкие файлы", "Small files")
                    let sub = T("\(Fmt.count(it.smallCount)) шт., \(Fmt.bytes(it.smallSize))", "\(Fmt.count(it.smallCount)) items, \(Fmt.bytes(it.smallSize))")
                    labels.append((title, sub, r.insetBy(dx: 4, dy: 3), c, false, false))
                }

            case .noAccess:
                let c = dimmed(noAccessColor)
                ctx.setFillColor(c.cg)
                ctx.fill(r.insetBy(dx: 0.5, dy: 0.5))
                ctx.saveGState()
                ctx.clip(to: r)
                ctx.setStrokeColor(c.mix(.black, 0.25).cg)
                ctx.setLineWidth(1)
                var x = r.minX - r.height
                while x < r.maxX {
                    ctx.move(to: CGPoint(x: x, y: r.maxY))
                    ctx.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                    x += 6
                }
                ctx.strokePath()
                ctx.restoreGState()
                if style.labels && r.width >= 80 && r.height >= 24 {
                    labels.append((T("Нет доступа", "No access"), it.node.displayName, r.insetBy(dx: 4, dy: 3), c, true, false))
                }

            case .synthetic:
                if style.hidden.contains(it.category) { continue }
                let c = dimmed(catColor)
                ctx.setFillColor(c.cg)
                ctx.fill(r.insetBy(dx: 0.5, dy: 0.5))
                ctx.setStrokeColor(c.mix(.black, 0.3).cg)
                ctx.setLineWidth(1)
                ctx.stroke(r.insetBy(dx: 1, dy: 1))
                if style.labels && r.width >= 80 && r.height >= 24 {
                    labels.append((it.node.name, Fmt.bytes(it.node.size(style.mode)), r.insetBy(dx: 4, dy: 3), c, true, false))
                }
            }
        }

        ctx.setShouldAntialias(true)
        for l in labels {
            let ink: RGB = l.fill.luminance > 0.55 ? RGB(hex: 0x15161A) : .white
            let r = l.rect
            if l.header {
                drawText(l.title + "  " + (l.sub ?? ""), in: r, ctx: ctx, font: bold, color: ink)
            } else {
                drawText(l.title, in: CGRect(x: r.minX, y: r.minY, width: r.width, height: 12), ctx: ctx, font: l.strong ? bold : font, color: ink)
                if let sub = l.sub {
                    drawText(sub, in: CGRect(x: r.minX, y: r.minY + 12.5, width: r.width, height: 12), ctx: ctx, font: font, color: ink, alpha: 0.8)
                }
            }
        }
    }

    public static func drawText(_ s: String, in r: CGRect, ctx: CGContext, font: CTFont, color: RGB, alpha: CGFloat = 1) {
        guard r.width > 8 else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: alpha),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
        let fitted = CTLineCreateTruncatedLine(line, Double(r.width), .end, ellipsis) ?? ellipsis
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: r.minX, y: r.minY + CTFontGetAscent(font))
        CTLineDraw(fitted, ctx)
        ctx.restoreGState()
    }
}

extension RenderStyle {
    /// Folder header strips extend over the folder's inner padding.
    var headerInset: CGFloat { 2 }
}
