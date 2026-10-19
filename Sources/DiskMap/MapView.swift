import AppKit
import Combine
import Quartz
@preconcurrency import DiskMapCore

/// The treemap. Renders the layout into a bitmap and draws hover, selection,
/// tooltip and minimap on top of it.
final class MapView: NSView {
    let session: ScanSession

    private(set) var items: [LayoutItem] = []
    private var index: [ObjectIdentifier: Int] = [:]
    private var image: CGImage?
    /// Zoom and pan the bitmap was rendered at; used to scale it during gestures.
    private var imageZoom: CGFloat = 1
    private var imagePan: CGPoint = .zero
    private var thumbnail: CGImage?
    private var thumbnailKey = ""
    private var hover: Int?
    private var mouse: CGPoint?
    private var renderScheduled = false
    private var pendingTransition: MapTransition = .none
    private var settleTimer: Timer?
    private var lastRender = CACurrentMediaTime()
    private var bag = Set<AnyCancellable>()

    private struct Animation {
        let old: CGImage
        let oldFrom: CGRect, oldTo: CGRect
        let newFrom: CGRect, newTo: CGRect
        let start: CFTimeInterval
        let duration: CFTimeInterval
    }
    private var animation: Animation?
    private var animationTimer: Timer?

    private var spaceDown = false
    private var spaceDragged = false
    private var panAnchor: (mouse: CGPoint, pan: CGPoint)?

    init(session: ScanSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        session.mapView = self
        session.mapEvents
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .relayout(let t): self.scheduleRender(t)
                case .viewport: self.viewportChanged()
                case .overlay: self.needsDisplay = true
                }
            }
            .store(in: &bag)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scheduleRender(.none)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        session.mapSize = newSize
        session.setViewport(zoom: session.zoom, pan: session.pan)
        scheduleRender(.none)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleRender(.none)
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: - Rendering

    private func scheduleRender(_ t: MapTransition) {
        if case .none = t {} else { pendingTransition = t }
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in self?.renderNow() }
    }

    private func viewportChanged() {
        needsDisplay = true
        settleTimer?.invalidate()
        if CACurrentMediaTime() - lastRender > 0.12 {
            scheduleRender(.none)
        } else {
            settleTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRender(.none) }
            }
        }
    }

    private func renderNow() {
        renderScheduled = false
        let transition = pendingTransition
        pendingTransition = .none
        guard bounds.width > 2, bounds.height > 2, let view = session.viewNode, session.phase == .ready else {
            items = []
            index = [:]
            image = nil
            needsDisplay = true
            return
        }
        let oldImage = image
        let oldItems = items
        let oldIndex = index

        let scale = window?.backingScaleFactor ?? 2
        let style = session.renderStyle(dark: isDark)
        items = TreemapLayout.layout(view, session.layoutParams(size: bounds.size))
        index.removeAll(keepingCapacity: true)
        for (i, it) in items.enumerated() where it.kind != .small { index[ObjectIdentifier(it.node)] = i }
        image = MapRenderer.render(items, size: bounds.size, scale: scale, style: style)
        imageZoom = session.zoom
        imagePan = session.pan
        lastRender = CACurrentMediaTime()
        updateThumbnail(view: view, style: style, scale: scale)
        hover = mouse.flatMap(hitIndex)

        if let old = oldImage {
            startAnimation(transition, old: old, oldItems: oldItems, oldIndex: oldIndex)
        }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func updateThumbnail(view: Node, style: RenderStyle, scale: CGFloat) {
        guard session.zoom > 1 else { return }
        let key = "\(ObjectIdentifier(view).hashValue)-\(session.treeVersion)-\(session.depthLimit)-\(session.sizeMode.rawValue)-\(bounds.size)-\(isDark)"
        guard key != thumbnailKey else { return }
        thumbnailKey = key
        var p = session.layoutParams(size: bounds.size)
        p.zoom = 1
        p.pan = .zero
        var s = style
        s.labels = false
        thumbnail = MapRenderer.render(TreemapLayout.layout(view, p), size: bounds.size, scale: 0.25, style: s)
    }

    /// Frame that blows `r` up to fill the bounds.
    private func expanded(_ r: CGRect) -> CGRect {
        let sx = bounds.width / max(r.width, 1), sy = bounds.height / max(r.height, 1)
        return CGRect(x: -r.minX * sx, y: -r.minY * sy, width: bounds.width * sx, height: bounds.height * sy)
    }

    private func rect(of node: Node, items: [LayoutItem], index: [ObjectIdentifier: Int]) -> CGRect? {
        var cur: Node? = node
        while let c = cur {
            if let i = index[ObjectIdentifier(c)] { return items[i].rect }
            cur = c.parent
        }
        return nil
    }

    private func startAnimation(_ t: MapTransition, old: CGImage, oldItems: [LayoutItem], oldIndex: [ObjectIdentifier: Int]) {
        let b = bounds
        var a: Animation?
        let now = CACurrentMediaTime()
        switch t {
        case .none:
            return
        case .fade:
            a = Animation(old: old, oldFrom: b, oldTo: b, newFrom: b, newTo: b, start: now, duration: 0.22)
        case .zoomIn(let node):
            if let r = rect(of: node, items: oldItems, index: oldIndex) {
                a = Animation(old: old, oldFrom: b, oldTo: expanded(r), newFrom: r, newTo: b, start: now, duration: 0.26)
            } else {
                a = Animation(old: old, oldFrom: b, oldTo: b, newFrom: b, newTo: b, start: now, duration: 0.22)
            }
        case .zoomOut(let node):
            if let r = rect(of: node, items: items, index: index) {
                a = Animation(old: old, oldFrom: b, oldTo: r, newFrom: expanded(r), newTo: b, start: now, duration: 0.26)
            } else {
                a = Animation(old: old, oldFrom: b, oldTo: b, newFrom: b, newTo: b, start: now, duration: 0.22)
            }
        }
        animation = a
        animationTimer?.invalidate()
        animationTimer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let a = self.animation else { timer.invalidate(); return }
                if CACurrentMediaTime() - a.start >= a.duration {
                    self.animation = nil
                    timer.invalidate()
                }
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bg = session.renderStyle(dark: isDark).background
        ctx.setFillColor(bg.cg)
        ctx.fill(bounds)
        guard let image else { return }

        if let a = animation {
            let raw = min(1, (CACurrentMediaTime() - a.start) / a.duration)
            let t = CGFloat(1 - pow(1 - raw, 3))
            drawImage(image, in: lerp(a.newFrom, a.newTo, t), ctx: ctx, alpha: min(1, t * 1.6))
            drawImage(a.old, in: lerp(a.oldFrom, a.oldTo, t), ctx: ctx, alpha: 1 - t)
            return
        }

        // Gestures update zoom/pan immediately; until re-rendered, scale the last bitmap.
        let k = session.zoom / imageZoom
        let frame = CGRect(x: imagePan.x * k - session.pan.x, y: imagePan.y * k - session.pan.y,
                           width: bounds.width * k, height: bounds.height * k)
        ctx.interpolationQuality = k == 1 ? .none : .medium
        drawImage(image, in: frame, ctx: ctx, alpha: 1)
        guard k == 1, frame.origin == .zero else { return }

        drawSelection(ctx)
        drawHover(ctx)
        drawMinimap(ctx)
        drawTooltip()
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    private func drawImage(_ img: CGImage, in r: CGRect, ctx: CGContext, alpha: CGFloat) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: 0, y: r.minY + r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: r)
        ctx.restoreGState()
    }

    private var ink: NSColor { isDark ? .white : .black }

    private func drawSelection(_ ctx: CGContext) {
        let accent = NSColor.controlAccentColor
        for n in session.selection {
            guard let i = index[ObjectIdentifier(n)] else { continue }
            let r = items[i].rect
            ctx.setFillColor(accent.withAlphaComponent(0.18).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(2.5)
            ctx.stroke(r.insetBy(dx: 1.25, dy: 1.25))
        }
    }

    private func drawHover(_ ctx: CGContext) {
        guard let h = hover, h < items.count else { return }
        // Parent folders up to the current view: thin outlines.
        var p = items[h].parent
        ctx.setLineWidth(1)
        while p >= 0 {
            let r = items[Int(p)].rect
            ctx.setStrokeColor(ink.withAlphaComponent(0.55).cgColor)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            p = items[Int(p)].parent
        }
        let r = items[h].rect
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(r.insetBy(dx: 1, dy: 1))
    }

    private var minimapRect: CGRect? {
        guard session.zoom > 1, thumbnail != nil else { return nil }
        let w: CGFloat = 180, h = w * bounds.height / max(bounds.width, 1)
        return CGRect(x: bounds.maxX - w - 12, y: bounds.maxY - h - 12, width: w, height: h)
    }

    private func drawMinimap(_ ctx: CGContext) {
        guard let m = minimapRect, let thumb = thumbnail else { return }
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(m.insetBy(dx: -3, dy: -3))
        ctx.setShadow(offset: .zero, blur: 0)
        drawImage(thumb, in: m, ctx: ctx, alpha: 1)
        let z = session.zoom
        let v = CGRect(x: m.minX + session.pan.x / z * m.width / bounds.width,
                       y: m.minY + session.pan.y / z * m.height / bounds.height,
                       width: m.width / z, height: m.height / z)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(v.insetBy(dx: -1, dy: -1))
    }

    private func drawTooltip() {
        guard let h = hover, h < items.count, let m = mouse, !spaceDown else { return }
        let lines = tooltipLines(items[h])
        guard !lines.isEmpty else { return }
        let text = NSMutableAttributedString()
        for (i, l) in lines.enumerated() {
            let font: NSFont = i == 0 ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 11)
            let color: NSColor = i == lines.count - 1 && lines.count > 2 ? .secondaryLabelColor : .labelColor
            text.append(NSAttributedString(string: (i > 0 ? "\n" : "") + l, attributes: [.font: font, .foregroundColor: color]))
        }
        let maxW: CGFloat = 420
        let size = text.boundingRect(with: CGSize(width: maxW, height: 400), options: [.usesLineFragmentOrigin]).size
        var r = CGRect(x: m.x + 16, y: m.y + 18, width: ceil(size.width) + 16, height: ceil(size.height) + 12)
        if r.maxX > bounds.maxX - 4 { r.origin.x = m.x - r.width - 8 }
        if r.maxY > bounds.maxY - 4 { r.origin.y = m.y - r.height - 8 }
        r.origin.x = max(4, r.origin.x)
        r.origin.y = max(4, r.origin.y)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        text.draw(with: r.insetBy(dx: 8, dy: 6), options: [.usesLineFragmentOrigin])
    }

    func tooltipLines(_ it: LayoutItem) -> [String] {
        let n = it.node
        let mode = session.sizeMode
        let cat = { (c: UInt8) in Int(c) < self.session.table.defs.count ? self.session.table.defs[Int(c)].name : "" }
        let level = T("Уровень \(n.depth + (it.kind == .small ? 1 : 0)) от корня", "Level \(n.depth + (it.kind == .small ? 1 : 0)) from root")
        switch it.kind {
        case .small:
            return [T("Мелкие файлы (\(Fmt.count(it.smallCount)) шт., \(Fmt.bytes(it.smallSize)))", "Small files (\(Fmt.count(it.smallCount)) items, \(Fmt.bytes(it.smallSize)))"),
                    T("Слишком мелкие, чтобы показать по отдельности — приблизьте карту", "Too small to show one by one — zoom in"),
                    T("Категория: ", "Category: ") + cat(it.category), level, n.path]
        case .synthetic:
            return [n.name, Fmt.bytes(n.physical), T("Не файлы: служебный блок тома", "Not files: volume summary block")]
        case .noAccess:
            return [n.name, T("Нет доступа — размер неизвестен", "No access — size unknown"),
                    T("Выдайте Полный доступ к диску и пересканируйте", "Grant Full Disk Access and rescan"), level, n.path]
        default:
            var l = [n.displayName]
            var size = Fmt.bytes(n.size(mode))
            let other = n.size(mode == .physical ? .logical : .physical)
            if other != n.size(mode) { size += "  (" + (mode == .physical ? T("логический: ", "logical: ") : T("физический: ", "physical: ")) + Fmt.bytes(other) + ")" }
            if n.isDirectory { size += " · " + Fmt.count(Int(n.fileCount)) + " " + Fmt.filesWord(Int(n.fileCount)) }
            l.append(size)
            l.append(T("Категория: ", "Category: ") + cat(it.kind == .collapsed ? n.category : it.category))
            if n.flags.contains(.dataless) { l.append(T("Выгружен в iCloud, место на диске не занимает", "Stored in iCloud, takes no local space")) }
            if n.flags.contains(.hardlinkDuplicate) { l.append(T("Жёсткая ссылка: размер учтён в другом месте", "Hard link: size counted elsewhere")) }
            if let reason = session.deletionBlockReason(n), n.parent != nil { l.append(reason) }
            l.append(level)
            l.append(n.path)
            return l
        }
    }

    // MARK: - Hit testing

    func hitIndex(_ p: CGPoint) -> Int? {
        guard animation == nil else { return nil }
        for i in items.indices.reversed() where items[i].rect.contains(p) { return i }
        return nil
    }

    /// The node a click at `p` refers to (merged small files select their folder).
    func node(at p: CGPoint) -> Node? {
        guard let i = hitIndex(p) else { return nil }
        return items[i].node
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        let h = mouse.flatMap(hitIndex)
        if h != hover || hover != nil { hover = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        hover = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let m = minimapRect, m.contains(p) {
            let z = session.zoom
            let cx = (p.x - m.minX) / m.width * bounds.width * z, cy = (p.y - m.minY) / m.height * bounds.height * z
            session.setViewport(zoom: z, pan: CGPoint(x: cx - bounds.width / 2, y: cy - bounds.height / 2))
            return
        }
        if spaceDown {
            spaceDragged = true
            panAnchor = (p, session.pan)
            NSCursor.closedHand.set()
            return
        }
        let hit = hitIndex(p)
        let n = hit.map { items[$0].node }
        if event.clickCount == 2, let hit {
            let it = items[hit]
            switch it.kind {
            case .folder, .collapsed: session.zoomIn(it.node)
            case .small: session.zoomIn(it.node)
            case .file:
                if let parent = it.node.parent, parent !== session.viewNode { session.zoomIn(parent) } else { toggleQuickLook() }
            default: break
            }
            return
        }
        session.select(n, toggle: event.modifierFlags.contains(.command))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let a = panAnchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        session.setViewport(zoom: session.zoom, pan: CGPoint(x: a.pan.x - (p.x - a.mouse.x), y: a.pan.y - (p.y - a.mouse.y)))
    }

    override func mouseUp(with event: NSEvent) {
        if panAnchor != nil {
            panAnchor = nil
            (spaceDown ? NSCursor.openHand : NSCursor.arrow).set()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            session.zoom(by: exp(dy * 0.01), at: p)
            return
        }
        if session.zoom > 1 {
            session.panBy(dx: -event.scrollingDeltaX, dy: -event.scrollingDeltaY)
            return
        }
        // Two-finger horizontal swipe on an unzoomed map: back / forward.
        if event.phase == .began, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), NSEvent.isSwipeTrackingFromScrollEventsEnabled {
            var done = false
            event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin: -1, max: 1) { [weak self] amount, phase, complete, _ in
                guard let self, !done else { return }
                if phase == .ended, complete || abs(amount) > 0.3 {
                    done = true
                    MainActor.assumeIsolated { amount > 0 ? self.session.goBack() : self.session.goForward() }
                }
            }
        }
    }

    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 { session.goBack() } else if event.deltaX < 0 { session.goForward() }
    }

    override func magnify(with event: NSEvent) {
        session.zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        if session.zoom > 1 { session.resetZoom() } else { session.zoom(by: 4, at: convert(event.locationInWindow, from: nil)) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let n = node(at: p) else { return nil }
        if !session.isSelected(n) { session.select(n) }
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: enabled ? sel : nil, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        add(n.isDirectory ? T("Приблизить", "Zoom In") : T("Открыть", "Open"), #selector(ctxZoom), enabled: !n.isSynthetic)
        add(T("Показать в Finder", "Show in Finder"), #selector(ctxReveal), enabled: !n.isSynthetic)
        add(T("Быстрый просмотр", "Quick Look"), #selector(ctxQuickLook), enabled: !n.isSynthetic)
        add(T("Скопировать путь", "Copy Path"), #selector(ctxCopyPath), enabled: !n.isSynthetic)
        m.addItem(.separator())
        add(T("Пересканировать", "Rescan"), #selector(ctxRescan), enabled: !n.isSynthetic && !session.isBusy)
        m.addItem(.separator())
        let reason = session.deletionBlockReason(n)
        add(T("В корзину", "Move to Trash"), #selector(ctxTrash), enabled: reason == nil)
        if let reason {
            let info = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            info.isEnabled = false
            m.addItem(info)
        }
        return m
    }

    @objc private func ctxZoom() { session.zoomIn() }
    @objc private func ctxReveal() { Actions.revealInFinder(session.selection) }
    @objc private func ctxQuickLook() { toggleQuickLook() }
    @objc private func ctxCopyPath() { Actions.copyPaths(session.selection) }
    @objc private func ctxRescan() { session.rescan(session.primary) }
    @objc private func ctxTrash() { session.deleteSelection(permanently: false) }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 49: // space: Quick Look on release, or hold and drag to pan
            if !event.isARepeat {
                spaceDown = true
                spaceDragged = false
                NSCursor.openHand.set()
                needsDisplay = true
            }
        case 123: moveSelection(.previous)
        case 124: moveSelection(.next)
        case 125: moveSelection(.child)
        case 126: moveSelection(.parent)
        case 36, 76: session.zoomIn()
        case 53:
            if !session.searchText.isEmpty { session.clearSearch() } else { session.select(nil) }
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            NSCursor.arrow.set()
            if !spaceDragged { toggleQuickLook() }
            needsDisplay = true
            return
        }
        super.keyUp(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+"=" as a synonym of Cmd+"+" on layouts where "+" needs Shift.
        if window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "=" {
            session.stepZoom(in: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private enum Move { case previous, next, child, parent }

    private func moveSelection(_ move: Move) {
        guard let view = session.viewNode else { return }
        guard let cur = session.primary, cur.isInside(view), cur !== view else {
            if let first = view.children.first { session.select(first); announce(first) }
            return
        }
        var target: Node?
        switch move {
        case .previous, .next:
            if let p = cur.parent, let i = p.children.firstIndex(where: { $0 === cur }) {
                let j = move == .next ? i + 1 : i - 1
                if p.children.indices.contains(j) { target = p.children[j] }
            }
        case .child: target = cur.children.first
        case .parent: target = cur.parent === view ? nil : cur.parent
        }
        if let target {
            session.select(target)
            announce(target)
        } else {
            NSSound.beep()
        }
    }

    private func announce(_ n: Node) {
        let cat = session.table.defs[Int(n.category)].name
        let text = "\(n.displayName), \(Fmt.bytes(n.size(session.sizeMode))), \(cat)"
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Quick Look

    func toggleQuickLook() {
        window?.makeFirstResponder(self)
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else if !quickLookURLs.isEmpty {
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    fileprivate var quickLookURLs: [URL] {
        session.selection.filter { !$0.isSynthetic && session.isAttached($0) }.map { URL(fileURLWithPath: $0.path) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    // MARK: - Accessibility

    override func accessibilityLabel() -> String? {
        guard let v = session.viewNode else { return T("Карта диска", "Disk map") }
        return T("Карта диска: \(v.displayName), \(Fmt.bytes(v.size(session.sizeMode)))", "Disk map: \(v.displayName), \(Fmt.bytes(v.size(session.sizeMode)))")
    }

    override func accessibilityChildren() -> [Any]? {
        guard let window else { return [] }
        var result: [Any] = []
        for it in items where (it.depth == 1 || session.isSelected(it.node)) && it.rect.width >= 8 && it.rect.height >= 8 {
            let lines = tooltipLines(it)
            let label = lines.prefix(3).joined(separator: ", ")
            let screen = window.convertToScreen(convert(it.rect.intersection(bounds), to: nil))
            if let e = NSAccessibilityElement.element(withRole: .button, frame: screen, label: label, parent: self) as? NSAccessibilityElement {
                result.append(e)
            }
            if result.count >= 150 { break }
        }
        return result
    }
}

extension MapView: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = quickLookURLs
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}

/// Small helpers shared by menus, context menus and the inspector.
enum Actions {
    static func revealInFinder(_ nodes: [Node]) {
        let urls = nodes.filter { !$0.isSynthetic }.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copyPaths(_ nodes: [Node]) {
        let paths = nodes.filter { !$0.isSynthetic }.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }
}
