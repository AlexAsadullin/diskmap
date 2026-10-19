import Foundation
import CoreGraphics

public struct LayoutItem {
    public enum Kind: UInt8 {
        case file
        /// Expanded folder: frame, optional header, children inside.
        case folder
        /// Folder drawn as one solid block (depth limit or too small to open).
        case collapsed
        /// Children of `node` too small to draw, merged into one grey block.
        case small
        case noAccess
        case synthetic
    }

    public var rect: CGRect
    public let node: Node
    public let kind: Kind
    /// Level below the current view (its children are level 1).
    public let depth: Int16
    /// Index of the enclosing folder item, or -1.
    public let parent: Int32
    public var category: UInt8
    public var headerHeight: CGFloat = 0
    public var smallCount: Int = 0
    public var smallSize: Int64 = 0
}

public struct LayoutParams {
    public var size: CGSize
    public var zoom: CGFloat = 1
    /// Top-left of the visible part of the zoomed map, in view points.
    public var pan: CGPoint = .zero
    /// 0 = all levels.
    public var depthLimit: Int = 0
    public var mode: SizeMode = .physical
    /// Items smaller than this many square points are merged into a "small files" block.
    public var minArea: Double = 1
    public var padding: CGFloat = 2
    public var headerHeight: CGFloat = 15
    public var headerLevels: Int = 2
    public var minFolderSide: CGFloat = 8
    /// Colour category for folders drawn as a solid block.
    public var dominantCategory: (Node) -> UInt8 = { $0.category }

    public init(size: CGSize) { self.size = size }
}

public enum TreemapLayout {
    /// Squarified treemap (Bruls, Huizing, van Wijk). `areas` must be sorted in descending order
    /// and sum to the area of `rect`. Large items end up in the top-left corner.
    public static func squarify(_ areas: [Double], in rect: CGRect) -> [CGRect] {
        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var r = rect
        var i = 0
        while i < areas.count {
            let w = Double(min(r.width, r.height))
            if w <= 0 {
                while i < areas.count { result.append(CGRect(origin: r.origin, size: .zero)); i += 1 }
                break
            }
            var sum = areas[i], lo = areas[i], hi = areas[i]
            var worst = ratio(sum, lo, hi, w)
            var j = i + 1
            while j < areas.count {
                let a = areas[j]
                let s = sum + a
                let nw = ratio(s, min(lo, a), max(hi, a), w)
                if nw > worst { break }
                sum = s; lo = min(lo, a); hi = max(hi, a); worst = nw
                j += 1
            }
            let last = j == areas.count
            if r.width >= r.height {
                // Column on the left, items stacked top to bottom.
                let thick = last ? Double(r.width) : min(Double(r.width), sum / Double(r.height))
                var y = Double(r.minY)
                for k in i..<j {
                    let h = k == j - 1 ? Double(r.maxY) - y : areas[k] / thick
                    result.append(CGRect(x: Double(r.minX), y: y, width: thick, height: max(0, h)))
                    y += h
                }
                r = CGRect(x: r.minX + thick, y: r.minY, width: max(0, r.width - thick), height: r.height)
            } else {
                // Row on top, items left to right.
                let thick = last ? Double(r.height) : min(Double(r.height), sum / Double(r.width))
                var x = Double(r.minX)
                for k in i..<j {
                    let wdt = k == j - 1 ? Double(r.maxX) - x : areas[k] / thick
                    result.append(CGRect(x: x, y: Double(r.minY), width: max(0, wdt), height: thick))
                    x += wdt
                }
                r = CGRect(x: r.minX, y: r.minY + thick, width: r.width, height: max(0, r.height - thick))
            }
            i = j
        }
        return result
    }

    @inline(__always)
    private static func ratio(_ sum: Double, _ lo: Double, _ hi: Double, _ w: Double) -> Double {
        let s2 = sum * sum, w2 = w * w
        return max(w2 * hi / s2, s2 / (w2 * lo))
    }

    /// Lays out the contents of `view`. Only items intersecting the visible area are produced.
    /// Parents always precede their children in the result.
    public static func layout(_ view: Node, _ p: LayoutParams) -> [LayoutItem] {
        var items: [LayoutItem] = []
        let content = CGRect(x: -p.pan.x, y: -p.pan.y, width: p.size.width * p.zoom, height: p.size.height * p.zoom)
        let visible = CGRect(origin: .zero, size: p.size)
        if view.isDirectory {
            let engine = Engine(params: p, visible: visible)
            engine.layoutChildren(of: view, in: content.insetBy(dx: 1, dy: 1), depth: 1, parent: -1, into: &items)
        } else {
            items.append(LayoutItem(rect: content, node: view, kind: .file, depth: 1, parent: -1, category: view.category))
        }
        return items
    }

    private struct Engine {
        let params: LayoutParams
        let visible: CGRect

        func layoutChildren(of node: Node, in rect: CGRect, depth: Int, parent: Int32, into items: inout [LayoutItem]) {
            guard rect.width >= 1, rect.height >= 1, rect.intersects(visible) else { return }
            let mode = params.mode
            let kids = node.children
            let total = Double(node.size(mode))

            // Folders we could not read have no size; give them a small nominal area so they stay visible.
            var unreadable: [Node] = []
            for ch in kids.reversed() {
                if ch.size(mode) > 0 { break }
                if ch.flags.contains(.noAccess) && ch.children.isEmpty { unreadable.append(ch) }
                if unreadable.count == 8 { break }
            }
            let nominal = total > 0 ? total * 0.004 : 1
            let grand = total + nominal * Double(unreadable.count)
            guard grand > 0 else { return }
            let scale = Double(rect.width * rect.height) / grand

            var areas: [Double] = []
            var nodes: [Node?] = []
            var consumed = 0.0
            var smallFrom = kids.count
            for (i, ch) in kids.enumerated() {
                let s = Double(ch.size(mode))
                if s <= 0 || s * scale < params.minArea { smallFrom = i; break }
                areas.append(s * scale)
                nodes.append(ch)
                consumed += s
            }
            let rest = total - consumed
            var smallCount = 0
            if rest * scale > 0.01 {
                areas.append(rest * scale)
                nodes.append(nil)
                for ch in kids[smallFrom...] where ch.size(mode) > 0 {
                    smallCount += ch.isDirectory ? Int(ch.fileCount) : 1
                }
            }
            for ch in unreadable {
                areas.append(nominal * scale)
                nodes.append(ch)
            }

            let rects = TreemapLayout.squarify(areas, in: rect)
            for k in 0..<rects.count {
                let r = rects[k]
                guard r.width > 0, r.height > 0, r.intersects(visible) else { continue }
                if let ch = nodes[k] {
                    place(ch, in: r, depth: depth, parent: parent, into: &items)
                } else {
                    var item = LayoutItem(rect: r, node: node, kind: .small, depth: Int16(depth), parent: parent, category: node.category)
                    item.smallCount = smallCount
                    item.smallSize = Int64(rest)
                    items.append(item)
                }
            }
        }

        func place(_ ch: Node, in r: CGRect, depth: Int, parent: Int32, into items: inout [LayoutItem]) {
            let d = Int16(depth)
            if ch.isSynthetic {
                items.append(LayoutItem(rect: r, node: ch, kind: .synthetic, depth: d, parent: parent, category: ch.category))
                return
            }
            if !ch.isDirectory {
                items.append(LayoutItem(rect: r, node: ch, kind: .file, depth: d, parent: parent, category: ch.category))
                return
            }
            if ch.flags.contains(.noAccess) && ch.children.isEmpty {
                items.append(LayoutItem(rect: r, node: ch, kind: .noAccess, depth: d, parent: parent, category: ch.category))
                return
            }
            let expandable = (params.depthLimit == 0 || depth < params.depthLimit)
                && min(r.width, r.height) >= params.minFolderSide
                && !ch.children.isEmpty && ch.size(params.mode) > 0
            if !expandable {
                items.append(LayoutItem(rect: r, node: ch, kind: .collapsed, depth: d, parent: parent, category: params.dominantCategory(ch)))
                return
            }
            var item = LayoutItem(rect: r, node: ch, kind: .folder, depth: d, parent: parent, category: ch.category)
            var inner = r.insetBy(dx: params.padding, dy: params.padding)
            if depth <= params.headerLevels && inner.height >= params.headerHeight * 2.5 && inner.width >= 30 {
                item.headerHeight = params.headerHeight
                inner.origin.y += params.headerHeight
                inner.size.height -= params.headerHeight
            }
            let index = Int32(items.count)
            items.append(item)
            layoutChildren(of: ch, in: inner, depth: depth + 1, parent: index, into: &items)
        }
    }
}
