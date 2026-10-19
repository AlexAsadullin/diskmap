// Self-checks for DiskMapCore (XCTest is not shipped with the Command Line Tools).
// Usage: swift run -c release diskmap-checks [folder to compare with du ...]
import Foundation
import CoreGraphics
import DiskMapCore

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok { failures += 1 }
}
func section(_ s: String) { print("\n== " + s) }

func file(_ name: String, _ size: Int64, in parent: Node) -> Node {
    let n = Node(name: name, flags: [], physical: size, logical: size)
    n.parent = parent
    parent.children.append(n)
    return n
}
func folder(_ name: String, in parent: Node?) -> Node {
    let n = Node(name: name, flags: .directory)
    n.parent = parent
    parent?.children.append(n)
    return n
}

// MARK: squarify

section("Squarified layout")
do {
    let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
    let sizes: [Double] = [6, 6, 4, 3, 2, 2, 1]
    let total = sizes.reduce(0, +)
    let areas = sizes.map { $0 / total * Double(rect.width * rect.height) }
    let rects = TreemapLayout.squarify(areas, in: rect)
    let err = zip(areas, rects).map { abs(Double($1.width * $1.height) - $0) / $0 }.max() ?? 1
    check(err < 1e-9, "areas proportional to sizes (max error \(err))")
    check(rects.allSatisfy { rect.insetBy(dx: -0.001, dy: -0.001).contains($0) }, "all rectangles inside the bounds")
    var overlap = false
    for i in rects.indices { for j in rects.indices where i < j { if rects[i].intersection(rects[j]).width * rects[i].intersection(rects[j]).height > 0.001 { overlap = true } } }
    check(!overlap, "no overlaps")
    check(rects[0].minX == 0 && rects[0].minY == 0, "largest item in the top-left corner")
    let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max()!
    check(worst < 3, "aspect ratios near square (worst \(String(format: "%.2f", worst)))")
}

// MARK: tree layout

section("Treemap of a tree")
let root = folder("/demo", in: nil)
let a = folder("A", in: root)
let f2 = file("two.bin", 2_000_000_000, in: a)
let f1 = file("one.bin", 1_000_000_000, in: a)
for i in 0..<5000 { _ = file("tiny\(i)", 10, in: a) }
let b = folder("B", in: root)
let deep = folder("C", in: b)
_ = file("deep.mov", 500_000_000, in: deep)
TreeOps.aggregate(root)
TreeOps.sort(root, mode: .physical)
do {
    var p = LayoutParams(size: CGSize(width: 1200, height: 800))
    let items = TreemapLayout.layout(root, p)
    func area(_ n: Node) -> CGFloat { items.first { $0.node === n }.map { $0.rect.width * $0.rect.height } ?? 0 }
    let ratio = area(f2) / area(f1)
    check(abs(ratio - 2) / 2 < 0.02, "2 GB file has twice the area of 1 GB file (ratio \(String(format: "%.4f", ratio)))")
    let small = items.first { $0.kind == .small }
    check(small != nil && small!.smallCount == 5000, "sub-pixel files merged into one block (\(small?.smallCount ?? 0) files)")
    check(a.physical == 3_000_000_000 + 50_000, "folder size equals sum of contents")
    let byName = { (n: Node) in items.first { $0.node === n }?.rect }
    p.depthLimit = 1
    let shallow = TreemapLayout.layout(root, p)
    check(shallow.allSatisfy { $0.depth == 1 }, "depth 1 shows only first-level folders")
    check(shallow.first { $0.node === a }?.rect == byName(a), "folder rectangle unchanged when depth changes")
    p.depthLimit = 0
    p.zoom = 8
    p.pan = CGPoint(x: 0, y: 0)
    let zoomed = TreemapLayout.layout(root, p)
    check(zoomed.allSatisfy { $0.rect.intersects(CGRect(x: 0, y: 0, width: 1200, height: 800)) }, "zoomed layout culls invisible items (\(zoomed.count) items)")
}

// MARK: categories

section("Categories")
do {
    let home = "/Users/test"
    let t = CategoryTable(home: home)
    let r = folder("/", in: nil)
    let apps = folder("Applications", in: r)
    let app = folder("Foo.app", in: apps)
    let appFile = file("bin", 10, in: app)
    let users = folder("Users", in: r)
    let me = folder("test", in: users)
    let lib = folder("Library", in: me)
    let mob = folder("Mobile Documents", in: lib)
    let icloudFile = file("doc.pages", 10, in: mob)
    let cache = file("cache.db", 10, in: lib)
    let docs = folder("Documents", in: me)
    let proj = folder("proj", in: docs)
    let nm = folder("node_modules", in: proj)
    let nmFile = file("index.js", 10, in: nm)
    let docFile = file("cv.pdf", 10, in: proj)
    let repo = folder("repo", in: me)
    repo.flags.insert(.gitRepository)
    let repoFile = file("main.c", 10, in: repo)
    let movies = folder("Movies", in: me)
    let mov = file("a.mov", 10, in: movies)
    let sys = folder("System", in: r)
    let sysFile = file("kernel", 10, in: sys)
    let trash = folder(".Trash", in: me)
    let trashFile = file("old", 10, in: trash)
    TreeOps.aggregate(r)
    t.categorize(root: r)
    func cat(_ n: Node) -> String { t.defs[Int(n.category)].id }
    check(cat(appFile) == "apps", "/Applications → Applications")
    check(cat(mov) == "movies", "~/Movies → Movies")
    check(cat(icloudFile) == "icloud", "~/Library/Mobile Documents → iCloud, not App Data")
    check(cat(cache) == "library", "~/Library → App Data & Caches")
    check(cat(nmFile) == "development", "node_modules inside Documents → Development")
    check(cat(docFile) == "documents", "~/Documents → Documents")
    check(cat(repoFile) == "development", "folder with .git → Development")
    check(cat(sysFile) == "system", "/System → System")
    check(cat(trashFile) == "trash", "~/.Trash → Trash")
    check(t.isProtected(path: "/System/Library", category: t.index(of: "other")!), "/System is protected")
    check(!t.isProtected(path: "/Users/test/Movies/a.mov", category: t.index(of: "movies")!), "user files are not protected")
    check(CategoryTable.normalize("/System/Volumes/Data/Users/x") == "/Users/x", "data volume paths normalized")

    let custom = CategoryDef(id: "custom.games", nameRU: "Игры", nameEN: "Games", hex: 0x123456, patterns: ["Steam*"], isCustom: true)
    let t2 = CategoryTable(colors: ["movies": 0x000001], custom: [custom], home: home)
    let steam = folder("SteamLibrary", in: docs)
    let game = file("game.pak", 10, in: steam)
    t2.categorize(root: r)
    check(t2.defs[Int(game.category)].id == "custom.games", "custom name pattern category")
    check(t2.defs[Int(t2.index(of: "movies")!)].hex == 0x000001, "colour override applied")
}

// MARK: archive

section("Save / open scan result")
do {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("check-\(getpid()).diskmap")
    try ScanArchive.write(ScanDocument(root: root, date: Date(timeIntervalSince1970: 1_700_000_000), volume: nil), to: url)
    let doc = try ScanArchive.read(from: url)
    try? FileManager.default.removeItem(at: url)
    var c1 = 0, c2 = 0
    root.forEach { _ in c1 += 1 }
    doc.root.forEach { _ in c2 += 1 }
    check(c1 == c2 && doc.root.physical == root.physical && doc.root.path == "/demo", "round trip keeps \(c2) nodes and sizes")
    check(doc.date.timeIntervalSince1970 == 1_700_000_000, "scan date kept")
    check(doc.root.find(path: "/demo/B/C/deep.mov")?.physical == 500_000_000, "paths resolve after loading")
} catch {
    check(false, "archive round trip: \(error)")
}

// MARK: deletion bookkeeping

section("Removing and restoring nodes")
do {
    let before = root.physical
    TreeOps.remove(f2, mode: .physical)
    check(root.physical == before - 2_000_000_000 && a.physical == 1_000_000_000 + 50_000, "parents shrink immediately")
    TreeOps.insert(f2, into: a, mode: .physical)
    check(root.physical == before && a.children.first === f2, "restore puts sizes and order back")
}

// MARK: scanner vs du

func du(_ path: String) -> Int64? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    p.arguments = ["-skx", path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return out.split(separator: "\t").first.flatMap { Int64($0) }.map { $0 * 1024 }
}

section("Scanner vs du -skx")
let paths = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : ["/usr/share", "/Library/Developer/CommandLineTools"]
for path in paths {
    let start = Date()
    let scanner = DiskScanner(rootPath: path)
    guard let tree = scanner.run() else { check(false, "scan \(path)"); continue }
    let secs = Date().timeIntervalSince(start)
    let duStart = Date()
    guard let ref = du(path) else { check(false, "du \(path)"); continue }
    let duSecs = Date().timeIntervalSince(duStart)
    let diff = ref == 0 ? 0 : abs(Double(tree.physical - ref)) / Double(ref) * 100
    check(diff <= 1, "\(path): \(Fmt.bytes(tree.physical)) vs du \(Fmt.bytes(ref)), diff \(String(format: "%.3f", diff))%, \(tree.fileCount) files, scan \(String(format: "%.2f", secs)) s, du \(String(format: "%.2f", duSecs)) s")
}

// MARK: performance

section("Performance on 1 000 000 files")
do {
    var rng = SystemRandomNumberGenerator()
    let big = folder("/big", in: nil)
    var made = 0
    func fill(_ dir: Node, depth: Int) {
        let subdirs = depth < 3 ? 10 : 0
        for i in 0..<subdirs { fill(folder("d\(i)", in: dir), depth: depth + 1) }
        if depth == 3 {
            for i in 0..<1000 {
                let s = Int64(pow(10, Double.random(in: 2...9, using: &rng)))
                _ = file("f\(i).dat", s, in: dir)
                made += 1
            }
        }
    }
    fill(big, depth: 0)
    TreeOps.aggregate(big)
    TreeOps.sort(big, mode: .physical)
    print("  built \(made) files")
    let palette = CategoryTable().defs.map { RGB(hex: $0.hex) }
    var p = LayoutParams(size: CGSize(width: 1160, height: 780))
    var t0 = Date()
    var items = TreemapLayout.layout(big, p)
    let layoutMs = Date().timeIntervalSince(t0) * 1000
    t0 = Date()
    _ = MapRenderer.render(items, size: p.size, scale: 2, style: RenderStyle(dark: true, palette: palette))
    let renderMs = Date().timeIntervalSince(t0) * 1000
    print("  zoom ×1: \(items.count) items, layout \(Int(layoutMs)) ms, render \(Int(renderMs)) ms")
    check(layoutMs + renderMs < 250, "full redraw under 250 ms")
    p.zoom = 16
    p.pan = CGPoint(x: 4000, y: 3000)
    t0 = Date()
    items = TreemapLayout.layout(big, p)
    _ = MapRenderer.render(items, size: p.size, scale: 2, style: RenderStyle(dark: false, palette: palette))
    print("  zoom ×16: \(items.count) items, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    let victim = big.children[0].children[0].children[0].children[0]
    t0 = Date()
    TreeOps.remove(victim, mode: .physical)
    items = TreemapLayout.layout(big, LayoutParams(size: p.size))
    let delMs = Date().timeIntervalSince(t0) * 1000
    check(delMs < 100, "map recalculated after delete in \(Int(delMs)) ms (≤ 100)")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
