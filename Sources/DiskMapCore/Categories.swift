import Foundation

public struct CategoryDef: Codable, Equatable, Identifiable {
    public var id: String
    public var nameRU: String
    public var nameEN: String
    /// 0xRRGGBB
    public var hex: UInt32
    /// Absolute paths or globs ("~" allowed). A pattern without "/" matches folder names.
    public var patterns: [String]
    public var isCustom: Bool
    /// Not a folder category: free space, purgeable space, snapshots.
    public var isSpecial: Bool

    public init(id: String, nameRU: String, nameEN: String, hex: UInt32, patterns: [String], isCustom: Bool = false, isSpecial: Bool = false) {
        self.id = id
        self.nameRU = nameRU
        self.nameEN = nameEN
        self.hex = hex
        self.patterns = patterns
        self.isCustom = isCustom
        self.isSpecial = isSpecial
    }

    public var name: String { T(nameRU, nameEN) }
}

/// Immutable category rules. A folder's category is decided by the nearest matching folder above it.
public final class CategoryTable {
    public static let builtins: [CategoryDef] = [
        CategoryDef(id: "apps", nameRU: "Приложения", nameEN: "Applications", hex: 0xE5484D, patterns: ["/Applications", "~/Applications"]),
        CategoryDef(id: "movies", nameRU: "Фильмы", nameEN: "Movies", hex: 0x3E63DD, patterns: ["~/Movies"]),
        CategoryDef(id: "music", nameRU: "Музыка", nameEN: "Music", hex: 0x8E4EC6, patterns: ["~/Music"]),
        CategoryDef(id: "pictures", nameRU: "Фото и изображения", nameEN: "Photos & Pictures", hex: 0xD6409F, patterns: ["~/Pictures"]),
        CategoryDef(id: "documents", nameRU: "Документы", nameEN: "Documents", hex: 0x30A46C, patterns: ["~/Documents"]),
        CategoryDef(id: "desktop", nameRU: "Рабочий стол", nameEN: "Desktop", hex: 0x12A594, patterns: ["~/Desktop"]),
        CategoryDef(id: "downloads", nameRU: "Загрузки", nameEN: "Downloads", hex: 0xF76B15, patterns: ["~/Downloads"]),
        CategoryDef(id: "icloud", nameRU: "iCloud Drive", nameEN: "iCloud Drive", hex: 0x0090FF, patterns: ["~/Library/Mobile Documents"]),
        CategoryDef(id: "library", nameRU: "Данные приложений и кэши", nameEN: "App Data & Caches", hex: 0xFFC53D, patterns: ["~/Library", "/Library"]),
        CategoryDef(id: "development", nameRU: "Разработка", nameEN: "Development", hex: 0x7CB518, patterns: ["~/Developer", ".git", "node_modules", "DerivedData"]),
        CategoryDef(id: "system", nameRU: "Система", nameEN: "System", hex: 0x60646C, patterns: ["/System", "/usr", "/bin", "/sbin", "/private", "/opt"]),
        CategoryDef(id: "trash", nameRU: "Корзина", nameEN: "Trash", hex: 0xA18072, patterns: ["~/.Trash"]),
        CategoryDef(id: "other", nameRU: "Прочее", nameEN: "Other", hex: 0xB9BBC6, patterns: []),
        CategoryDef(id: "free", nameRU: "Свободно", nameEN: "Free", hex: 0xE6E8EB, patterns: [], isSpecial: true),
        CategoryDef(id: "purgeable", nameRU: "Очищаемое (purgeable)", nameEN: "Purgeable", hex: 0x9FD8C4, patterns: [], isSpecial: true),
        CategoryDef(id: "reserved", nameRU: "Снимки и служебные тома", nameEN: "Snapshots & system volumes", hex: 0x43484E, patterns: [], isSpecial: true),
    ]

    public let defs: [CategoryDef]
    public let other: UInt8
    public let development: UInt8
    public let system: UInt8
    public let free: UInt8
    public let purgeable: UInt8
    public let reserved: UInt8

    private let home: String
    private var exactPaths: [String: UInt8] = [:]
    private var pathGlobs: [(String, UInt8)] = []
    private var nameGlobs: [(String, UInt8)] = []
    private var devNames: Set<String> = []
    private var devPaths: Set<String> = []
    private var customExact: [String: UInt8] = [:]

    /// - Parameters:
    ///   - colors: per-category colour overrides keyed by category id.
    ///   - custom: user categories; they take precedence over built-in rules.
    public init(colors: [String: UInt32] = [:], custom: [CategoryDef] = [], home: String = NSHomeDirectory()) {
        var all = CategoryTable.builtins
        all.append(contentsOf: custom.prefix(200))
        for i in all.indices { if let c = colors[all[i].id] { all[i].hex = c } }
        defs = all
        self.home = home
        func idx(_ id: String) -> UInt8 { UInt8(all.firstIndex { $0.id == id }!) }
        other = idx("other"); development = idx("development"); system = idx("system")
        free = idx("free"); purgeable = idx("purgeable"); reserved = idx("reserved")

        for (i, def) in all.enumerated() where !def.isSpecial {
            let index = UInt8(i)
            for pattern in def.patterns {
                let p = expand(pattern)
                let isGlob = p.contains("*") || p.contains("?") || p.contains("[")
                if def.id == "development" {
                    if p.contains("/") { devPaths.insert(p) } else if p != ".git" { devNames.insert(p) }
                } else if def.isCustom {
                    if p.contains("/") {
                        if isGlob { pathGlobs.append((p, index)) } else { customExact[p] = index }
                    } else {
                        nameGlobs.append((p, index))
                    }
                } else {
                    exactPaths[p] = index
                }
            }
        }
    }

    public func index(of id: String) -> UInt8? {
        defs.firstIndex { $0.id == id }.map { UInt8($0) }
    }

    private func expand(_ p: String) -> String {
        var s = p
        if s == "~" { s = home } else if s.hasPrefix("~/") { s = home + s.dropFirst(1) }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Maps paths seen through the data volume mount onto their firmlinked form.
    public static func normalize(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        if path == data { return "/" }
        if path.hasPrefix(data + "/") { return String(path.dropFirst(data.count)) }
        return path
    }

    /// The category a folder at `path` starts, or nil to inherit from its parent.
    private func ownCategory(path: String, name: Substring, hasGit: Bool) -> UInt8? {
        if let c = customExact[path] { return c }
        for (g, c) in pathGlobs where fnmatch(g, path, 0) == 0 { return c }
        for (g, c) in nameGlobs where fnmatch(g, String(name), 0) == 0 { return c }
        if hasGit || devNames.contains(String(name)) || devPaths.contains(path) { return development }
        return exactPaths[path]
    }

    /// Category for a scan root, looking at the folders above it on disk.
    public func initialCategory(forPath raw: String) -> UInt8 {
        let path = CategoryTable.normalize(raw)
        var cur = path
        while !cur.isEmpty && cur != "/" {
            let name = (cur as NSString).lastPathComponent
            let git = FileManager.default.fileExists(atPath: cur + "/.git")
            if let c = ownCategory(path: cur, name: Substring(name), hasGit: git) { return c }
            cur = (cur as NSString).deletingLastPathComponent
        }
        return other
    }

    /// Assigns categories to the whole tree.
    public func categorize(root: Node) {
        let path = CategoryTable.normalize(root.path)
        categorize(subtree: root, path: path, category: initialCategory(forPath: path))
    }

    /// Assigns categories below `node`, whose own category is `category`.
    public func categorize(subtree node: Node, path: String, category: UInt8) {
        var stack: [(Node, String, UInt8)] = [(node, path, category)]
        while let (n, p, c) = stack.popLast() {
            if !n.isSynthetic { n.category = c }
            let prefix = p.hasSuffix("/") ? p : p + "/"
            for ch in n.children where !ch.isSynthetic {
                if ch.isDirectory {
                    let cp = prefix + ch.name
                    let own = ownCategory(path: cp, name: Substring(ch.name), hasGit: ch.flags.contains(.gitRepository))
                    stack.append((ch, cp, own ?? c))
                } else {
                    ch.category = c
                }
            }
        }
    }

    /// Bytes per category over the files of the tree.
    public func totals(of root: Node, mode: SizeMode) -> [Int64] {
        var t = [Int64](repeating: 0, count: defs.count)
        root.forEach { n in
            if !n.isDirectory, Int(n.category) < t.count { t[Int(n.category)] += n.size(mode) }
        }
        return t
    }

    private static let protectedPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private", "/cores", "/dev"]

    /// System items cannot be deleted from the map.
    public func isProtected(path raw: String, category: UInt8) -> Bool {
        if category == system { return true }
        let path = CategoryTable.normalize(raw)
        if path == "/" { return true }
        if path.hasPrefix("/usr/local") { return false }
        return CategoryTable.protectedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Data of other applications: deleting it may reset settings.
    public func isLibraryData(path raw: String) -> Bool {
        let path = CategoryTable.normalize(raw)
        return path.hasPrefix(home + "/Library/") || path.hasPrefix("/Library/")
    }
}
