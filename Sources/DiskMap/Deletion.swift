import AppKit
@preconcurrency import DiskMapCore

/// Moving items to the Trash or deleting them, with confirmation, undo and the journal.
extension ScanSession {
    struct TrashRecord {
        let node: Node
        let parent: Node
        let original: URL
        let trashed: URL
    }

    /// Why a node cannot be deleted, or nil.
    func deletionBlockReason(_ n: Node) -> String? {
        if n.isSynthetic { return T("Это не файл, а служебный блок тома", "This is a volume summary block, not a file") }
        if n.parent == nil { return T("Нельзя удалить корень сканирования", "The scan root cannot be deleted") }
        if table.isProtected(path: n.path, category: n.category) {
            return T("Системный элемент: удаление запрещено", "System item: deletion is not allowed")
        }
        if volume?.readOnly == true || VolumeInfo.isReadOnly(path: n.path) {
            return T("Том доступен только для чтения", "The volume is read-only")
        }
        return nil
    }

    var canDeleteSelection: Bool {
        selection.contains { deletionBlockReason($0) == nil }
    }

    /// Cmd+Backspace / Cmd+Option+Backspace.
    func deleteSelection(permanently: Bool) {
        guard phase == .ready, !isBusy else { return }
        if permanently && !AppSettings.shared.allowPermanentDelete {
            let a = NSAlert()
            a.messageText = T("Окончательное удаление выключено", "Permanent deletion is turned off")
            a.informativeText = T("Включите его в Настройках, если хотите удалять файлы мимо Корзины.", "Turn it on in Settings to delete files without the Trash.")
            a.runModal()
            return
        }
        var targets = selection.filter(isAttached)
        targets = targets.filter { t in !targets.contains { $0 !== t && t.isInside($0) } }
        let blocked = targets.compactMap { n in deletionBlockReason(n).map { (n, $0) } }
        targets = targets.filter { deletionBlockReason($0) == nil }
        guard !targets.isEmpty else {
            let a = NSAlert()
            a.messageText = T("Эти объекты нельзя удалить", "These items cannot be deleted")
            a.informativeText = blocked.map { "• \($0.0.displayName): \($0.1)" }.joined(separator: "\n")
            a.runModal()
            return
        }
        guard confirm(targets, blocked: blocked.map(\.0), permanently: permanently) else { return }
        perform(targets, permanently: permanently)
    }

    private func confirm(_ targets: [Node], blocked: [Node], permanently: Bool) -> Bool {
        if !permanently && !AppSettings.shared.confirmTrash { return true }
        let total = targets.reduce(Int64(0)) { $0 + $1.physical }
        let files = targets.reduce(0) { $0 + Int($1.fileCount) }
        var lines = targets.prefix(12).map { n -> String in
            var s = "• \(n.displayName) — \(Fmt.bytes(n.physical))"
            if n.isDirectory { s += T(" (\(Fmt.count(Int(n.fileCount))) \(Fmt.filesWord(Int(n.fileCount))))", " (\(Fmt.count(Int(n.fileCount))) files)") }
            return s
        }
        if targets.count > 12 { lines.append(T("…и ещё \(targets.count - 12)", "…and \(targets.count - 12) more")) }
        lines.append("")
        lines.append(T("Всего: \(Fmt.bytes(total)), \(Fmt.count(files)) \(Fmt.filesWord(files)).", "Total: \(Fmt.bytes(total)), \(Fmt.count(files)) files."))
        if targets.contains(where: { table.isLibraryData(path: $0.path) }) {
            lines.append("")
            lines.append(T("⚠︎ Среди них есть данные приложений из Library. Их удаление может сбросить настройки или нарушить работу программ.",
                           "⚠︎ Some items are application data in Library. Deleting them may reset settings or break apps."))
        }
        if !blocked.isEmpty {
            lines.append("")
            lines.append(T("Пропущены (системные): ", "Skipped (system): ") + blocked.map(\.displayName).joined(separator: ", "))
        }
        if permanently {
            lines.append("")
            lines.append(T("Это действие необратимо: файлы не попадут в Корзину.", "This cannot be undone: the files will not go to the Trash."))
        }

        let a = NSAlert()
        a.alertStyle = permanently ? .critical : .warning
        a.messageText = permanently
            ? T("Удалить навсегда \(targets.count) объект(ов)?", "Delete \(targets.count) item(s) permanently?")
            : T("Переместить \(targets.count) объект(ов) в Корзину?", "Move \(targets.count) item(s) to the Trash?")
        a.informativeText = lines.joined(separator: "\n")
        let ok = a.addButton(withTitle: permanently ? T("Удалить навсегда", "Delete Permanently") : T("В корзину", "Move to Trash"))
        ok.hasDestructiveAction = true
        a.addButton(withTitle: T("Отменить", "Cancel"))
        if !permanently {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = T("Больше не спрашивать для Корзины", "Don't ask again for the Trash")
        }
        let response = a.runModal()
        if response == .alertFirstButtonReturn, a.suppressionButton?.state == .on {
            AppSettings.shared.confirmTrash = false
        }
        return response == .alertFirstButtonReturn
    }

    /// Deletes without asking (confirmation already given, or redo).
    func perform(_ targets: [Node], permanently: Bool) {
        var records: [TrashRecord] = []
        var errors: [String] = []
        var freed: Int64 = 0
        var apps: [(name: String, bundleID: String?)] = []
        let fm = FileManager.default

        for n in targets {
            guard let parent = n.parent else { continue }
            let path = n.path
            let url = URL(fileURLWithPath: path)
            let isApp = n.name.hasSuffix(".app") && table.defs[Int(n.category)].id == "apps"
            let bundleID = isApp ? Bundle(url: url)?.bundleIdentifier : nil
            do {
                if permanently {
                    try fm.removeItem(at: url)
                    Journal.log("delete", size: n.physical, path: path)
                } else {
                    var out: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &out)
                    if let trashed = out as URL? {
                        records.append(TrashRecord(node: n, parent: parent, original: url, trashed: trashed))
                    }
                    Journal.log("trash", size: n.physical, path: path)
                }
                if let v = viewNode, v.isInside(n) { setView(parent) }
                mutate { TreeOps.remove(n, mode: sizeMode) }
                freed += n.physical
                if isApp { apps.append((String(n.name.dropLast(4)), bundleID)) }
            } catch {
                errors.append("• \(n.displayName): \(ScanSession.describe(error))")
            }
        }

        addFreed(freed)
        if !records.isEmpty {
            undoManager.registerUndo(withTarget: self) { s in s.restore(records) }
            undoManager.setActionName(T("перемещение в Корзину", "Move to Trash"))
        }
        treeChanged()
        forgetDetached()
        relayout(.fade)

        if !errors.isEmpty {
            let a = NSAlert()
            a.messageText = T("Не все объекты удалось удалить", "Some items could not be deleted")
            a.informativeText = errors.joined(separator: "\n")
            a.runModal()
        }
        for app in apps { offerLeftovers(appName: app.name, bundleID: app.bundleID) }
    }

    /// Cmd+Z: puts items back from the Trash.
    func restore(_ records: [TrashRecord]) {
        var restored: [Node] = []
        var errors: [String] = []
        for r in records.reversed() {
            do {
                try FileManager.default.createDirectory(at: r.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: r.trashed, to: r.original)
                Journal.log("restore", size: r.node.physical, path: r.original.path)
                if isAttached(r.parent) || r.parent === root {
                    mutate { TreeOps.insert(r.node, into: r.parent, mode: sizeMode) }
                    restored.append(r.node)
                }
                addFreed(-r.node.physical)
            } catch {
                errors.append("• \(r.original.lastPathComponent): \(ScanSession.describe(error))")
            }
        }
        if !restored.isEmpty {
            undoManager.registerUndo(withTarget: self) { s in s.perform(restored, permanently: false) }
            undoManager.setActionName(T("перемещение в Корзину", "Move to Trash"))
            selection = restored
        }
        treeChanged()
        relayout(.fade)
        if !errors.isEmpty {
            let a = NSAlert()
            a.messageText = T("Не удалось вернуть из Корзины", "Could not put back from the Trash")
            a.informativeText = errors.joined(separator: "\n")
            a.runModal()
        }
    }

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        if let posix = (e.userInfo[NSUnderlyingErrorKey] as? NSError), posix.domain == NSPOSIXErrorDomain {
            switch Int32(posix.code) {
            case EBUSY: return T("файл занят другим процессом", "the file is in use by another process")
            case EACCES, EPERM: return T("нет прав на удаление", "permission denied")
            case EROFS: return T("том только для чтения", "read-only volume")
            default: break
            }
        }
        switch e.code {
        case CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileReadNoPermission.rawValue:
            return T("нет прав на удаление", "permission denied")
        case CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue:
            return T("файл уже не существует", "the file no longer exists")
        default:
            return e.localizedDescription
        }
    }

    /// After an app is trashed, offers its data in ~/Library for manual selection.
    private func offerLeftovers(appName: String, bundleID: String?) {
        let lib = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        var candidates: [String] = ["\(lib)/Application Support/\(appName)", "\(lib)/Caches/\(appName)", "\(lib)/Logs/\(appName)"]
        if let id = bundleID {
            candidates += ["\(lib)/Application Support/\(id)", "\(lib)/Caches/\(id)", "\(lib)/Containers/\(id)",
                           "\(lib)/Preferences/\(id).plist", "\(lib)/Saved Application State/\(id).savedState",
                           "\(lib)/HTTPStorages/\(id)", "\(lib)/WebKit/\(id)"]
        }
        let existing = Array(Set(candidates)).sorted().filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }

        let a = NSAlert()
        a.messageText = T("Данные приложения «\(appName)»", "Data of \"\(appName)\"")
        a.informativeText = T("Приложение в Корзине. В Library остались его данные — отметьте, что тоже переместить в Корзину:",
                              "The app is in the Trash. Its data is still in Library — select what to move to the Trash too:")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        var boxes: [(NSButton, String)] = []
        for p in existing {
            let size = root?.find(path: p).map { Fmt.bytes($0.physical) } ?? "—"
            let title = p.replacingOccurrences(of: lib, with: "~/Library") + "  (\(size))"
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.state = .off
            stack.addArrangedSubview(b)
            boxes.append((b, p))
        }
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: CGFloat(existing.count) * 22)
        a.accessoryView = stack
        a.addButton(withTitle: T("В корзину", "Move to Trash"))
        a.addButton(withTitle: T("Оставить", "Keep"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let chosen = boxes.filter { $0.0.state == .on }.map(\.1)
        var nodes: [Node] = []
        for p in chosen {
            if let n = root?.find(path: p) {
                nodes.append(n)
            } else {
                var out: NSURL?
                if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &out)) != nil {
                    Journal.log("trash", size: 0, path: p)
                }
            }
        }
        if !nodes.isEmpty { perform(nodes, permanently: false) }
    }
}
