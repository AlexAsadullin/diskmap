import AppKit
import Combine
@preconcurrency import DiskMapCore

enum MapTransition {
    case none
    /// Zooming into a folder that is visible on the current map.
    case zoomIn(Node)
    /// Zooming out; the argument is the previous view, now a block on the new map.
    case zoomOut(Node)
    case fade
}

enum MapEvent {
    case relayout(MapTransition)
    /// Zoom or pan changed: scale the current bitmap now, re-render shortly.
    case viewport
    /// Selection or highlight changed; no new layout needed.
    case overlay
}

/// Cancellation flag shared with a background search.
final class CancelFlag: @unchecked Sendable { var cancelled = false }

/// State of one scan window: the tree, the current view, selection and history.
@MainActor
final class ScanSession: ObservableObject {
    enum Phase: Equatable { case empty, scanning, ready, failed(String) }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var root: Node?
    @Published private(set) var viewNode: Node?
    @Published var depthLimit = 0 { didSet { if oldValue != depthLimit { relayout() } } }
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var pan: CGPoint = .zero
    @Published var selection: [Node] = [] { didSet { mapEvents.send(.overlay) } }
    @Published private(set) var sizeMode: SizeMode
    @Published private(set) var freedBytes: Int64 = 0
    @Published var searchText = ""
    @Published private(set) var searchResults: [Node] = []
    @Published private(set) var searchMatches: Set<ObjectIdentifier>?
    @Published private(set) var searching = false
    @Published var hiddenCategories: Set<UInt8> = [] { didSet { relayout() } }
    @Published var highlightCategory: UInt8? { didSet { if oldValue != highlightCategory { relayout() } } }
    @Published var showInspector = true
    @Published var showLegend = true
    @Published private(set) var categoryTotals: [Int64] = []
    @Published private(set) var progress = DiskScanner.Progress()
    @Published private(set) var treeVersion = 0
    @Published private(set) var rescanningPath: String?
    @Published var focusSearchToken = 0
    @Published private(set) var table: CategoryTable
    @Published private(set) var volume: VolumeInfo?
    @Published private(set) var noAccessCount = 0
    /// Bytes a whole-volume scan is expected to find, for the progress bar.
    private(set) var expectedBytes: Int64?

    private(set) var searchAncestors: Set<ObjectIdentifier> = []
    private(set) var scanDate = Date()
    private(set) var backStack: [Node] = []
    private(set) var forwardStack: [Node] = []
    private(set) var savedFrom: URL?
    let undoManager = UndoManager()
    let mapEvents = PassthroughSubject<MapEvent, Never>()
    weak var window: NSWindow?
    weak var mapView: MapView?
    /// Size of the map area, kept up to date by the map view.
    var mapSize = CGSize(width: 1000, height: 700)

    /// Held while a background search walks the tree; every mutation takes it too.
    let treeLock = NSLock()
    private var scanner: DiskScanner?
    private var progressTimer: Timer?
    private var dominantCache: [ObjectIdentifier: UInt8] = [:]
    private var searchFlag = CancelFlag()
    private var bag = Set<AnyCancellable>()

    init() {
        sizeMode = AppSettings.shared.defaultSizeMode
        table = AppSettings.shared.makeCategoryTable()
        $searchText
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] in self?.runSearch($0) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: AppSettings.changed)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &bag)
    }

    var title: String {
        guard let root else { return "DiskMap" }
        let name = root.displayName
        if let savedFrom { return "\(name) — \(savedFrom.lastPathComponent)" }
        return name
    }

    var expectedFraction: Double? {
        guard let e = expectedBytes, e > 0 else { return nil }
        return min(0.99, Double(progress.physical) / Double(e))
    }

    var isBusy: Bool { phase == .scanning || rescanningPath != nil }
    var primary: Node? { selection.last }

    func isAttached(_ n: Node) -> Bool {
        guard let root else { return false }
        return n.root === root
    }

    // MARK: - Scanning

    func startScan(path: String) {
        cancelScan()
        let scanner = DiskScanner(rootPath: path)
        self.scanner = scanner
        phase = .scanning
        root = nil
        viewNode = nil
        selection = []
        savedFrom = nil
        noAccessCount = 0
        progress = DiskScanner.Progress()
        backStack = []
        forwardStack = []
        undoManager.removeAllActions()
        scanner.onNoAccess = { [weak self] _ in
            DispatchQueue.main.async { Permissions.offerFullDiskAccess(for: self?.window) }
        }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak scanner] _ in
            guard let scanner else { return }
            MainActor.assumeIsolated { self?.progress = scanner.progress }
        }
        volume = VolumeInfo.forPath(scanner.rootPath)
        expectedBytes = volume.flatMap { v in VolumeInfo.isVolumeRoot(scanner.rootPath) ? v.capacity - v.available : nil }
        let mode = sizeMode
        let table = self.table
        let thread = Thread {
            guard let tree = scanner.run() else {
                DispatchQueue.main.async { self.scanEnded(nil, volume: nil, cancelled: scanner.isCancelled) }
                return
            }
            var vol = VolumeInfo.forPath(scanner.rootPath)
            if var v = vol, VolumeInfo.isVolumeRoot(scanner.rootPath) {
                v.snapshotCount = VolumeInfo.localSnapshotCount(mountPath: v.mountPath)
                vol = v
                VolumeInfo.addSyntheticBlocks(to: tree, volume: v, table: table)
            }
            TreeOps.sort(tree, mode: mode)
            table.categorize(root: tree)
            DispatchQueue.main.async { self.scanEnded(tree, volume: vol, cancelled: false) }
        }
        thread.stackSize = 64 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func scanEnded(_ tree: Node?, volume: VolumeInfo?, cancelled: Bool) {
        progressTimer?.invalidate()
        progressTimer = nil
        if let s = scanner { progress = s.progress; noAccessCount = s.progress.noAccess }
        scanner = nil
        guard let tree else {
            phase = cancelled ? .empty : .failed(T("Не удалось прочитать папку.", "Could not read the folder."))
            return
        }
        self.volume = volume
        scanDate = Date()
        install(tree)
    }

    private func install(_ tree: Node) {
        root = tree
        viewNode = tree
        zoom = 1
        pan = .zero
        selection = []
        phase = .ready
        treeChanged()
        relayout(.fade)
        if !searchText.isEmpty { runSearch(searchText) }
    }

    func cancelScan() {
        scanner?.cancel()
    }

    func load(url: URL) {
        phase = .scanning
        expectedBytes = nil
        progress = DiskScanner.Progress()
        progress.currentPath = url.path
        let mode = sizeMode
        let table = self.table
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let doc = try ScanArchive.read(from: url)
                TreeOps.sort(doc.root, mode: mode)
                table.categorize(root: doc.root)
                DispatchQueue.main.async {
                    self.volume = doc.volume
                    self.scanDate = doc.date
                    self.savedFrom = url
                    self.install(doc.root)
                }
            } catch {
                DispatchQueue.main.async { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func save(to url: URL) throws {
        guard let root else { return }
        try ScanArchive.write(ScanDocument(root: root, date: scanDate, volume: volume), to: url)
    }

    /// Rescans one folder and grafts the result into the tree.
    func rescan(_ target: Node? = nil) {
        guard let root, rescanningPath == nil, phase == .ready else { return }
        var node = target ?? (primary?.isDirectory == true ? primary! : viewNode ?? root)
        if node.isSynthetic || !node.isDirectory { node = node.parent ?? root }
        if node === root {
            startScan(path: root.name)
            return
        }
        let path = node.path
        let scanner = DiskScanner(rootPath: path)
        self.scanner = scanner
        rescanningPath = path
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak scanner] _ in
            guard let scanner else { return }
            MainActor.assumeIsolated { self?.progress = scanner.progress }
        }
        let mode = sizeMode
        let thread = Thread {
            let fresh = scanner.run()
            if let fresh { TreeOps.sort(fresh, mode: mode) }
            DispatchQueue.main.async { self.graft(fresh, into: node) }
        }
        thread.stackSize = 64 << 20
        thread.start()
    }

    private func graft(_ fresh: Node?, into node: Node) {
        progressTimer?.invalidate()
        progressTimer = nil
        scanner = nil
        rescanningPath = nil
        guard let fresh, isAttached(node) else { return }
        mutate {
            let dp = fresh.physical - node.physical, dl = fresh.logical - node.logical, df = fresh.fileCount - node.fileCount
            node.children = fresh.children
            for c in node.children { c.parent = node }
            node.flags = fresh.flags.union(.directory)
            node.physical = fresh.physical
            node.logical = fresh.logical
            node.fileCount = fresh.fileCount
            node.mtime = fresh.mtime
            TreeOps.propagate(from: node, physical: dp, logical: dl, files: df, mode: sizeMode)
            table.categorize(subtree: node, path: CategoryTable.normalize(node.path), category: node.category)
        }
        selection = selection.filter(isAttached)
        treeChanged()
        relayout(.fade)
    }

    // MARK: - Tree changes

    /// Runs a tree mutation after stopping any background search that is reading the tree.
    func mutate(_ body: () -> Void) {
        searchFlag.cancelled = true
        treeLock.lock()
        body()
        treeLock.unlock()
    }

    func treeChanged() {
        dominantCache = [:]
        if let root { categoryTotals = table.totals(of: root, mode: sizeMode) }
        treeVersion += 1
    }

    func relayout(_ t: MapTransition = .none) {
        mapEvents.send(.relayout(t))
    }

    private func settingsChanged() {
        table = AppSettings.shared.makeCategoryTable()
        if let root {
            mutate { table.categorize(root: root) }
            treeChanged()
        }
        objectWillChange.send()
        relayout()
    }

    func toggleSizeMode() {
        sizeMode = sizeMode == .physical ? .logical : .physical
        if let root {
            mutate { TreeOps.sort(root, mode: sizeMode) }
            treeChanged()
        }
        relayout(.fade)
    }

    /// Colour for a folder drawn as one block: the category holding most of its bytes.
    func dominantCategory(_ n: Node) -> UInt8 {
        let id = ObjectIdentifier(n)
        if let c = dominantCache[id] { return c }
        var sums = [Int64](repeating: 0, count: table.defs.count)
        n.forEach { x in if !x.isDirectory, Int(x.category) < sums.count { sums[Int(x.category)] += x.size(sizeMode) } }
        let best = sums.indices.max { sums[$0] < sums[$1] }
        let c = best.flatMap { sums[$0] > 0 ? UInt8($0) : nil } ?? n.category
        dominantCache[id] = c
        return c
    }

    func layoutParams(size: CGSize) -> LayoutParams {
        var p = LayoutParams(size: size)
        p.zoom = zoom
        p.pan = pan
        p.depthLimit = depthLimit
        p.mode = sizeMode
        p.dominantCategory = { [unowned self] in self.dominantCategory($0) }
        return p
    }

    func renderStyle(dark: Bool) -> RenderStyle {
        var s = RenderStyle(dark: dark, palette: table.defs.map { RGB(hex: $0.hex) })
        s.hidden = hiddenCategories
        s.highlight = highlightCategory
        s.matches = searchMatches
        s.matchAncestors = searchAncestors
        s.mode = sizeMode
        return s
    }

    // MARK: - Navigation

    func navigate(to n: Node, record: Bool = true) {
        guard let current = viewNode, n.isDirectory, n !== current, isAttached(n) else { return }
        if record {
            backStack.append(current)
            forwardStack.removeAll()
        }
        show(n, from: current)
    }

    private func show(_ n: Node, from current: Node) {
        let transition: MapTransition
        if n.isInside(current) { transition = .zoomIn(n) } else if current.isInside(n) { transition = .zoomOut(current) } else { transition = .fade }
        viewNode = n
        zoom = 1
        pan = .zero
        if case .zoomOut(let old) = transition { selection = [old] }
        relayout(transition)
        objectWillChange.send()
    }

    /// Cmd+↓ / double click: zoom into a folder, open a file.
    func zoomIn(_ target: Node? = nil) {
        guard let n = target ?? primary else { return }
        if n.isSynthetic { return }
        if !n.isDirectory {
            NSWorkspace.shared.open(URL(fileURLWithPath: n.path))
            return
        }
        if n.flags.contains(.noAccess) && n.children.isEmpty { return }
        navigate(to: n)
    }

    func zoomOut() {
        guard let v = viewNode, let p = v.parent else { return }
        navigate(to: p)
    }

    func zoomToRoot() {
        guard let root else { return }
        navigate(to: root)
    }

    var canZoomOut: Bool { viewNode?.parent != nil }
    var canGoBack: Bool { backStack.contains(where: isAttached) }
    var canGoForward: Bool { forwardStack.contains(where: isAttached) }

    func goBack() {
        guard let current = viewNode else { return }
        while let n = backStack.popLast() {
            if isAttached(n) {
                forwardStack.append(current)
                show(n, from: current)
                return
            }
        }
    }

    func goForward() {
        guard let current = viewNode else { return }
        while let n = forwardStack.popLast() {
            if isAttached(n) {
                backStack.append(current)
                show(n, from: current)
                return
            }
        }
    }

    /// Path from the root to the current view, for the breadcrumb bar.
    var breadcrumbs: [Node] {
        guard let v = viewNode else { return [] }
        return (v.ancestors.reversed() + [v])
    }

    // MARK: - Free zoom

    static let maxZoom: CGFloat = 64

    func setViewport(zoom z: CGFloat, pan p: CGPoint) {
        let nz = min(max(z, 1), ScanSession.maxZoom)
        let maxX = mapSize.width * (nz - 1), maxY = mapSize.height * (nz - 1)
        let np = CGPoint(x: min(max(p.x, 0), maxX), y: min(max(p.y, 0), maxY))
        guard nz != zoom || np != pan else { return }
        zoom = nz
        pan = np
        mapEvents.send(.viewport)
    }

    /// Zooms keeping the map point under `anchor` (view coordinates) in place.
    func zoom(by factor: CGFloat, at anchor: CGPoint? = nil) {
        let a = anchor ?? CGPoint(x: mapSize.width / 2, y: mapSize.height / 2)
        let nz = min(max(zoom * factor, 1), ScanSession.maxZoom)
        let k = nz / zoom
        setViewport(zoom: nz, pan: CGPoint(x: (pan.x + a.x) * k - a.x, y: (pan.y + a.y) * k - a.y))
    }

    func panBy(dx: CGFloat, dy: CGFloat) {
        setViewport(zoom: zoom, pan: CGPoint(x: pan.x + dx, y: pan.y + dy))
    }

    func resetZoom() { setViewport(zoom: 1, pan: .zero) }

    /// Animated Cmd+"+" / Cmd+"−".
    func stepZoom(in zoomingIn: Bool) {
        let start = zoom, target = min(max(zoom * (zoomingIn ? 2 : 0.5), 1), ScanSession.maxZoom)
        let began = CACurrentMediaTime()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, (CACurrentMediaTime() - began) / 0.22)
                let eased = 1 - pow(1 - t, 3)
                let z = start * pow(target / start, CGFloat(eased))
                self.zoom(by: z / self.zoom)
                if t >= 1 { timer.invalidate() }
            }
        }
    }

    // MARK: - Selection

    func select(_ n: Node?, toggle: Bool = false) {
        guard let n else { if !toggle { selection = [] }; return }
        if toggle {
            if let i = selection.firstIndex(where: { $0 === n }) { selection.remove(at: i) } else { selection.append(n) }
        } else if !(selection.count == 1 && selection[0] === n) {
            selection = [n]
        }
    }

    /// Selects a node and, if it is outside the current view, moves the view to show it.
    func reveal(_ n: Node) {
        guard isAttached(n) else { return }
        if let v = viewNode, !n.isInside(v) || n === v, let p = n.parent {
            navigate(to: p)
        }
        selection = [n]
    }

    func isSelected(_ n: Node) -> Bool { selection.contains { $0 === n } }

    // MARK: - Search

    private func runSearch(_ text: String) {
        searchFlag.cancelled = true
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let root else {
            if searchMatches != nil { searchMatches = nil; searchResults = []; searchAncestors = []; relayout() }
            searching = false
            return
        }
        let flag = CancelFlag()
        searchFlag = flag
        searching = true
        let mode = sizeMode
        let lock = treeLock
        DispatchQueue.global(qos: .userInitiated).async {
            lock.lock()
            var found: [Node] = []
            var seen = 0
            var stack: [Node] = [root]
            while let n = stack.popLast() {
                seen += 1
                if seen & 4095 == 0 && flag.cancelled { break }
                if n !== root, !n.isSynthetic, n.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    found.append(n)
                }
                if n.isDirectory { stack.append(contentsOf: n.children) }
            }
            var ancestors = Set<ObjectIdentifier>()
            if !flag.cancelled {
                found.sort { $0.size(mode) > $1.size(mode) }
                for n in found.prefix(20000) {
                    var p = n.parent
                    while let c = p, ancestors.insert(ObjectIdentifier(c)).inserted { p = c.parent }
                }
            }
            lock.unlock()
            if flag.cancelled { return }
            let matches = Set(found.prefix(20000).map(ObjectIdentifier.init))
            let results = Array(found.prefix(500))
            DispatchQueue.main.async {
                guard !flag.cancelled else { return }
                self.searchResults = results
                self.searchMatches = matches
                self.searchAncestors = ancestors
                self.searching = false
                self.relayout()
            }
        }
    }

    func clearSearch() { searchText = "" }

    // MARK: - Export

    func exportCSV(to url: URL) throws {
        guard let node = viewNode else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        CSVExport.write(node, table: table, mode: sizeMode) { h.write(Data($0.utf8)) }
    }

    func exportPNG(to url: URL, dark: Bool) throws {
        guard let view = viewNode else { return }
        let items = TreemapLayout.layout(view, layoutParams(size: mapSize))
        guard let img = MapRenderer.render(items, size: mapSize, scale: 2, style: renderStyle(dark: dark)),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: - Deletion bookkeeping (UI lives in Deletion.swift)

    func addFreed(_ bytes: Int64) { freedBytes += bytes }

    /// Drops references to removed nodes from selection, history and the view.
    func forgetDetached() {
        selection = selection.filter(isAttached)
        backStack = backStack.filter(isAttached)
        forwardStack = forwardStack.filter(isAttached)
        if let v = viewNode, !isAttached(v) {
            // Removed nodes keep no parent; walk the old view's ancestors captured before removal.
            viewNode = root
        }
        if searchMatches != nil { runSearch(searchText) }
    }

    func setView(_ n: Node) {
        viewNode = n
        zoom = 1
        pan = .zero
    }
}
