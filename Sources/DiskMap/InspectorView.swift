import SwiftUI
import AppKit
@preconcurrency import DiskMapCore

struct InspectorView: View {
    @ObservedObject var session: ScanSession
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(T("Сведения", "Info")).tag(0)
                Text(T("Дерево", "Tree")).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            if tab == 0 {
                DetailsPane(session: session)
            } else {
                TreeOutline(session: session)
            }
        }
    }
}

private struct DetailsPane: View {
    @ObservedObject var session: ScanSession
    @State private var largest: [Node] = []
    @State private var dataless = (count: 0, bytes: Int64(0))

    private var subject: Node? { session.primary ?? session.viewNode }
    private var statsKey: String {
        guard let s = subject else { return "" }
        return "\(ObjectIdentifier(s).hashValue)-\(session.treeVersion)-\(session.sizeMode.rawValue)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if session.searchMatches != nil { searchSection; Divider() }
                if session.selection.count > 1 {
                    multiSection
                } else if let n = subject {
                    details(n)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: statsKey) { computeStats() }
    }

    private func computeStats() {
        guard let n = subject, session.isAttached(n) || n === session.root else { largest = []; return }
        largest = n.isDirectory ? TreeOps.largestFiles(in: n, limit: 20, mode: session.sizeMode) : []
        var c = 0
        var b: Int64 = 0
        if n.isDirectory {
            n.forEach { x in if x.flags.contains(.dataless) { c += 1; b += x.logical } }
        }
        dataless = (c, b)
    }

    private var multiSection: some View {
        let nodes = session.selection
        let total = nodes.reduce(Int64(0)) { $0 + $1.size(session.sizeMode) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(T("Выбрано: \(nodes.count)", "Selected: \(nodes.count)")).font(.headline)
            Text(Fmt.bytes(total)).font(.title3.monospacedDigit())
            ForEach(nodes) { n in
                nodeRow(n, max: nodes.map { $0.size(session.sizeMode) }.max() ?? 1)
            }
            actionButtons(nodes)
        }
    }

    @ViewBuilder
    private func details(_ n: Node) -> some View {
        let mode = session.sizeMode
        let root = session.root
        HStack(alignment: .top, spacing: 10) {
            if n.isSynthetic {
                Image(systemName: "chart.pie").font(.system(size: 28))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: n.path)).resizable().frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(n.displayName).font(.headline).lineLimit(3).textSelection(.enabled)
                Text(Fmt.bytes(n.size(mode))).font(.title3.monospacedDigit())
            }
        }
        if !n.isSynthetic {
            Text(n.path)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }

        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            row(T("Физический", "Physical"), Fmt.bytes(n.physical))
            row(T("Логический", "Logical"), Fmt.bytes(n.logical))
            if let root { row(T("Доля от корня", "Share of root"), Fmt.percent(n.size(mode), of: root.size(mode))) }
            GridRow {
                Text(T("Категория", "Category")).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    let def = session.table.defs[Int(min(Int(n.category), session.table.defs.count - 1))]
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: RGB(hex: def.hex).nsColor)).frame(width: 10, height: 10)
                    Text(def.name)
                }
            }
            if n.mtime > 0 { row(T("Изменён", "Modified"), Fmt.date(n.modificationDate)) }
            if n.isDirectory { row(T("Файлов", "Files"), Fmt.count(Int(n.fileCount))) }
            if dataless.count > 0 {
                row(T("В iCloud", "In iCloud"), T("\(Fmt.count(dataless.count)) не загружено (\(Fmt.bytes(dataless.bytes)))", "\(Fmt.count(dataless.count)) not downloaded (\(Fmt.bytes(dataless.bytes)))"))
            }
            row(T("Уровень", "Level"), "\(n.depth)")
        }
        .font(.system(size: 12))

        if n.flags.contains(.noAccess) {
            Label(T("Нет доступа: содержимое не прочитано", "No access: contents not read"), systemImage: "lock.fill")
                .foregroundStyle(.orange).font(.callout)
        }
        if n.flags.contains(.dataless) {
            Label(T("Выгружен в iCloud — место на диске не занимает", "Stored in iCloud — takes no local space"), systemImage: "icloud")
                .font(.callout)
        }
        if n.flags.contains(.hardlinkDuplicate) {
            Label(T("Жёсткая ссылка: размер учтён в другом месте", "Hard link: size counted elsewhere"), systemImage: "link")
                .font(.callout)
        }
        if let reason = session.deletionBlockReason(n), n.parent != nil {
            Label(reason, systemImage: "hand.raised").foregroundStyle(.secondary).font(.callout)
        }

        if !n.isSynthetic { actionButtons([n]) }

        if !largest.isEmpty {
            Divider()
            Text(T("20 крупнейших файлов внутри", "20 largest files inside")).font(.subheadline.weight(.semibold))
            VStack(spacing: 2) {
                let maxSize = largest.first?.size(mode) ?? 1
                ForEach(largest) { f in nodeRow(f, max: maxSize, showParent: true) }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }

    private func nodeRow(_ n: Node, max: Int64, showParent: Bool = false) -> some View {
        let size = n.size(session.sizeMode)
        let def = session.table.defs[Int(min(Int(n.category), session.table.defs.count - 1))]
        return Button {
            session.reveal(n)
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: RGB(hex: def.hex).nsColor)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(n.displayName).lineLimit(1).truncationMode(.middle)
                    if showParent, let p = n.parent {
                        Text(p.displayName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(Fmt.bytes(size)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(alignment: .leading) {
                GeometryReader { g in
                    Rectangle().fill(Color.accentColor.opacity(0.10))
                        .frame(width: g.size.width * CGFloat(Double(size) / Double(Swift.max(max, 1))))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(n.path)
    }

    private func actionButtons(_ nodes: [Node]) -> some View {
        HStack {
            Button(T("Показать в Finder", "Show in Finder")) { Actions.revealInFinder(nodes) }
            Button(T("В корзину", "Move to Trash")) { session.deleteSelection(permanently: false) }
                .disabled(!session.canDeleteSelection)
        }
        .controlSize(.small)
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(T("Найдено: \(Fmt.count(session.searchMatches?.count ?? 0))", "Found: \(Fmt.count(session.searchMatches?.count ?? 0))"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(T("Сбросить", "Clear")) { session.clearSearch() }.controlSize(.small)
            }
            let results = session.searchResults.filter(session.isAttached).prefix(100)
            let maxSize = results.first?.size(session.sizeMode) ?? 1
            ForEach(Array(results)) { n in nodeRow(n, max: maxSize, showParent: true) }
        }
    }
}

// MARK: - Tree

/// Folder tree sorted by size, synchronised with the map selection.
struct TreeOutline: NSViewRepresentable {
    @ObservedObject var session: ScanSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SpaceOutlineView()
        outline.session = session
        outline.headerView = nil
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowSizeStyle = .small
        outline.allowsMultipleSelection = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (id, width) in [("check", 20.0), ("name", 150.0), ("size", 64.0), ("pct", 44.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.width = width
            c.minWidth = id == "name" ? 60 : width
            outline.addTableColumn(c)
            if id == "name" { outline.outlineTableColumn = c }
        }
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        context.coordinator.outline = outline
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        outline.reloadData()
        if let root = session.root { outline.expandItem(root) }
        context.coordinator.syncSelection()
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let c = context.coordinator
        if c.version != session.treeVersion || c.mode != session.sizeMode {
            c.version = session.treeVersion
            c.mode = session.sizeMode
            c.outline?.reloadData()
        }
        c.syncSelection()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let session: ScanSession
        weak var outline: NSOutlineView?
        var version = -1
        var mode: SizeMode = .physical
        private var syncing = false

        init(session: ScanSession) {
            self.session = session
            self.version = session.treeVersion
            self.mode = session.sizeMode
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let n = item as? Node else { return session.root == nil ? 0 : 1 }
            return n.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let n = item as? Node else { return session.root! }
            return n.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let n = item as? Node else { return false }
            return n.isDirectory && !n.children.isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let n = item as? Node, let col = tableColumn?.identifier.rawValue else { return nil }
            if col == "check" {
                let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
                b.state = session.isSelected(n) ? .on : .off
                b.isEnabled = !n.isSynthetic && n.parent != nil
                b.controlSize = .small
                return b
            }
            let cell = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingMiddle
            tf.font = .systemFont(ofSize: 11.5)
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            switch col {
            case "name":
                let def = session.table.defs[Int(min(Int(n.category), session.table.defs.count - 1))]
                let s = NSMutableAttributedString(string: "■ ", attributes: [.foregroundColor: RGB(hex: def.hex).nsColor, .font: NSFont.systemFont(ofSize: 11)])
                s.append(NSAttributedString(string: n.displayName, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11.5)]))
                tf.attributedStringValue = s
                tf.toolTip = n.path
            case "size":
                tf.stringValue = Fmt.bytes(n.size(session.sizeMode))
                tf.alignment = .right
                tf.textColor = .secondaryLabelColor
            default:
                let parentSize = n.parent?.size(session.sizeMode) ?? n.size(session.sizeMode)
                tf.stringValue = parentSize > 0 ? String(format: "%.0f%%", Double(n.size(session.sizeMode)) / Double(parentSize) * 100) : ""
                tf.alignment = .right
                tf.textColor = .tertiaryLabelColor
            }
            return cell
        }

        @objc func toggled(_ sender: NSButton) {
            guard let outline else { return }
            let row = outline.row(for: sender)
            guard row >= 0, let n = outline.item(atRow: row) as? Node else { return }
            session.select(n, toggle: true)
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard let n = sender.item(atRow: sender.clickedRow) as? Node else { return }
            session.zoomIn(n)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline, outline.selectedRow >= 0, let n = outline.item(atRow: outline.selectedRow) as? Node else { return }
            if !(session.selection.count == 1 && session.selection[0] === n) { session.reveal(n) }
        }

        /// Expands to and selects the map's primary selection; refreshes checkboxes.
        func syncSelection() {
            guard let outline else { return }
            syncing = true
            defer { syncing = false }
            if let n = session.primary, session.isAttached(n) {
                for a in n.ancestors.reversed() { outline.expandItem(a) }
                let row = outline.row(forItem: n)
                if row >= 0 {
                    if outline.selectedRow != row { outline.selectRowIndexes([row], byExtendingSelection: false) }
                    outline.scrollRowToVisible(row)
                }
            } else {
                outline.deselectAll(nil)
            }
            let visible = outline.rows(in: outline.visibleRect)
            for r in visible.location..<(visible.location + visible.length) {
                if let b = outline.view(atColumn: 0, row: r, makeIfNecessary: false) as? NSButton, let n = outline.item(atRow: r) as? Node {
                    b.state = session.isSelected(n) ? .on : .off
                }
            }
        }
    }
}

/// Space opens Quick Look from the tree, as on the map.
final class SpaceOutlineView: NSOutlineView {
    weak var session: ScanSession?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, let map = session?.mapView {
            map.toggleQuickLook()
            return
        }
        super.keyDown(with: event)
    }
}
