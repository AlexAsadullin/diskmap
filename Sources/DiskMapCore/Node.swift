import Foundation

public enum SizeMode: Int, Codable, CaseIterable {
    case physical = 0
    case logical = 1

    public var title: String {
        self == .physical ? T("физический", "physical") : T("логический", "logical")
    }
}

public struct NodeFlags: OptionSet, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let directory = NodeFlags(rawValue: 1 << 0)
    /// The folder could not be opened (permissions / TCC). Its size is unknown.
    public static let noAccess = NodeFlags(rawValue: 1 << 1)
    /// iCloud file or folder evicted to the cloud; never materialized by the scanner.
    public static let dataless = NodeFlags(rawValue: 1 << 2)
    /// Another hard link to an inode already counted elsewhere; sizes are zero.
    public static let hardlinkDuplicate = NodeFlags(rawValue: 1 << 3)
    public static let symlink = NodeFlags(rawValue: 1 << 4)
    /// Free space, purgeable space and other blocks that are not files.
    public static let synthetic = NodeFlags(rawValue: 1 << 5)
    /// The folder contains a ".git" entry.
    public static let gitRepository = NodeFlags(rawValue: 1 << 6)
    /// Listing of the folder stopped with an error part way through.
    public static let incomplete = NodeFlags(rawValue: 1 << 7)
}

/// One file or folder of the scanned tree. Kept compact: a scan may hold millions of them.
/// The root node's `name` is its absolute path; every other node stores only its own name.
public final class Node {
    public var name: String
    public unowned(unsafe) var parent: Node?
    /// Sorted by size, largest first (see `TreeOps.sort`).
    public var children: [Node] = []
    public var physical: Int64
    public var logical: Int64
    /// Number of files in the subtree (1 for a file).
    public var fileCount: Int32
    /// Modification time, seconds since 1970.
    public var mtime: UInt32
    public var flags: NodeFlags
    public var category: UInt8 = 0

    public init(name: String, flags: NodeFlags, physical: Int64 = 0, logical: Int64 = 0, mtime: UInt32 = 0) {
        self.name = name
        self.flags = flags
        self.physical = physical
        self.logical = logical
        self.mtime = mtime
        self.fileCount = flags.contains(.directory) || flags.contains(.synthetic) ? 0 : 1
    }

    @inline(__always) public var isDirectory: Bool { flags.contains(.directory) }
    @inline(__always) public var isSynthetic: Bool { flags.contains(.synthetic) }

    @inline(__always) public func size(_ mode: SizeMode) -> Int64 { mode == .physical ? physical : logical }

    public var path: String {
        var parts: [String] = []
        var cur = self
        while let p = cur.parent {
            parts.append(cur.name)
            cur = p
        }
        let base = cur.name
        if parts.isEmpty { return base }
        let tail = parts.reversed().joined(separator: "/")
        return base.hasSuffix("/") ? base + tail : base + "/" + tail
    }

    public var displayName: String {
        guard parent == nil else { return name }
        if name == "/" { return "/" }
        return (name as NSString).lastPathComponent
    }

    public var root: Node {
        var cur = self
        while let p = cur.parent { cur = p }
        return cur
    }

    /// Distance from the scan root (root = 0).
    public var depth: Int {
        var d = 0
        var cur = self
        while let p = cur.parent { d += 1; cur = p }
        return d
    }

    /// Parent, grandparent, … up to the root.
    public var ancestors: [Node] {
        var result: [Node] = []
        var cur = parent
        while let c = cur { result.append(c); cur = c.parent }
        return result
    }

    /// True when `self` is `other` or lies inside it.
    public func isInside(_ other: Node) -> Bool {
        var cur: Node? = self
        while let c = cur {
            if c === other { return true }
            cur = c.parent
        }
        return false
    }

    public var modificationDate: Date { Date(timeIntervalSince1970: TimeInterval(mtime)) }

    /// Visits the node and all its descendants without recursion.
    public func forEach(_ body: (Node) -> Void) {
        var stack: [Node] = [self]
        while let n = stack.popLast() {
            body(n)
            if n.isDirectory { stack.append(contentsOf: n.children) }
        }
    }

    /// Finds a descendant by absolute path, or nil.
    public func find(path target: String) -> Node? {
        let base = path
        if target == base { return self }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard target.hasPrefix(prefix) else { return nil }
        var cur = self
        for comp in target.dropFirst(prefix.count).split(separator: "/") {
            guard let next = cur.children.first(where: { $0.name == comp }) else { return nil }
            cur = next
        }
        return cur
    }
}

public enum TreeOps {
    /// Recomputes folder totals bottom-up: size and file count of a folder are the sums of its contents.
    public static func aggregate(_ root: Node) {
        var stack: [(Node, Bool)] = [(root, false)]
        while let (n, visited) = stack.popLast() {
            guard n.isDirectory else { continue }
            if visited {
                var p: Int64 = 0, l: Int64 = 0, c: Int32 = 0
                for ch in n.children {
                    p += ch.physical
                    l += ch.logical
                    c &+= ch.fileCount
                }
                n.physical = p
                n.logical = l
                n.fileCount = c
            } else {
                stack.append((n, true))
                for ch in n.children where ch.isDirectory { stack.append((ch, false)) }
            }
        }
    }

    /// Orders every folder's children by size, largest first.
    public static func sort(_ root: Node, mode: SizeMode) {
        root.forEach { n in
            if n.isDirectory && n.children.count > 1 { sortChildren(n, mode: mode) }
        }
    }

    public static func sortChildren(_ n: Node, mode: SizeMode) {
        n.children.sort { a, b in
            let sa = a.size(mode), sb = b.size(mode)
            if sa != sb { return sa > sb }
            if a.isSynthetic != b.isSynthetic { return !a.isSynthetic }
            return a.name < b.name
        }
    }

    /// Adds deltas to every ancestor of `node` and keeps their children ordered.
    public static func propagate(from node: Node, physical dp: Int64, logical dl: Int64, files df: Int32, mode: SizeMode) {
        var cur = node.parent
        while let c = cur {
            c.physical += dp
            c.logical += dl
            c.fileCount &+= df
            cur = c.parent
        }
        cur = node.parent
        while let c = cur {
            sortChildren(c, mode: mode)
            cur = c.parent
        }
    }

    /// Detaches a node from its parent and subtracts its size from all ancestors.
    public static func remove(_ node: Node, mode: SizeMode) {
        guard let parent = node.parent else { return }
        if let i = parent.children.firstIndex(where: { $0 === node }) {
            parent.children.remove(at: i)
        }
        propagate(from: node, physical: -node.physical, logical: -node.logical, files: -node.fileCount, mode: mode)
        node.parent = nil
    }

    /// Puts a previously removed node back under `parent`.
    public static func insert(_ node: Node, into parent: Node, mode: SizeMode) {
        node.parent = parent
        parent.children.append(node)
        propagate(from: node, physical: node.physical, logical: node.logical, files: node.fileCount, mode: mode)
    }

    /// Up to `limit` largest files inside `node`.
    public static func largestFiles(in node: Node, limit: Int, mode: SizeMode) -> [Node] {
        var best: [Node] = []
        var floor: Int64 = -1
        node.forEach { n in
            guard !n.isDirectory, !n.isSynthetic else { return }
            let s = n.size(mode)
            guard best.count < limit || s > floor else { return }
            let i = best.firstIndex(where: { $0.size(mode) < s }) ?? best.count
            best.insert(n, at: i)
            if best.count > limit { best.removeLast() }
            floor = best.last?.size(mode) ?? -1
        }
        return best
    }
}
