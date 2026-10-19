import Foundation

/// Lists a tree as CSV: folders first by size, depth-first.
public enum CSVExport {
    public static let header = "path,type,physical_bytes,logical_bytes,files,category,modified,flags\n"

    /// - Parameter maxDepth: levels below `root` to list (nil = all).
    public static func write(_ root: Node, table: CategoryTable, mode: SizeMode, maxDepth: Int? = nil, emit: (String) -> Void) {
        let iso = ISO8601DateFormatter()
        var chunk = header
        let rootPath = root.path
        var stack: [(Node, String, Int)] = [(root, rootPath, 0)]
        while let (n, path, depth) = stack.popLast() {
            let type = n.isSynthetic ? "special" : (n.isDirectory ? "folder" : (n.flags.contains(.symlink) ? "symlink" : "file"))
            var flags: [String] = []
            if n.flags.contains(.noAccess) { flags.append("no-access") }
            if n.flags.contains(.dataless) { flags.append("icloud-dataless") }
            if n.flags.contains(.hardlinkDuplicate) { flags.append("hardlink-duplicate") }
            let cat = Int(n.category) < table.defs.count ? table.defs[Int(n.category)].nameEN : ""
            chunk += [quote(path), type, String(n.physical), String(n.logical), String(n.fileCount), quote(cat),
                      n.mtime > 0 ? iso.string(from: n.modificationDate) : "", flags.joined(separator: "|")].joined(separator: ",")
            chunk += "\n"
            if chunk.utf8.count > 1 << 16 { emit(chunk); chunk = "" }
            if n.isDirectory, maxDepth.map({ depth < $0 }) ?? true {
                let prefix = path.hasSuffix("/") ? path : path + "/"
                for ch in n.children.reversed() {
                    stack.append((ch, ch.isSynthetic ? "[" + ch.name + "]" : prefix + ch.name, depth + 1))
                }
            }
        }
        if !chunk.isEmpty { emit(chunk) }
    }

    static func quote(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
