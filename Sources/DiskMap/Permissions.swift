import AppKit
@preconcurrency import DiskMapCore

enum Permissions {
    private static var offered = false
    private static let dontAskKey = "fullDiskAccessDontAsk"

    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(fullDiskAccessURL)
    }

    /// Shown the first time a folder cannot be opened.
    @MainActor
    static func offerFullDiskAccess(for window: NSWindow?) {
        guard !offered, !UserDefaults.standard.bool(forKey: dontAskKey) else { return }
        offered = true
        let alert = NSAlert()
        alert.messageText = T("Некоторые папки недоступны", "Some folders are not accessible")
        alert.informativeText = T(
            "macOS не даёт прочитать часть папок (Почта, Сообщения, данные других приложений). Они будут показаны серым блоком «Нет доступа». Чтобы увидеть всё, выдайте DiskMap Полный доступ к диску в Системных настройках и пересканируйте.",
            "macOS blocks some folders (Mail, Messages, other apps' data). They are shown as grey \"No access\" blocks. To see everything, grant DiskMap Full Disk Access in System Settings and rescan.")
        alert.addButton(withTitle: T("Открыть настройки", "Open System Settings"))
        alert.addButton(withTitle: T("Позже", "Later"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = T("Больше не спрашивать", "Don't ask again")
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: dontAskKey) }
            if r == .alertFirstButtonReturn { openFullDiskAccessSettings() }
        }
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}

/// Every deletion is appended to ~/Library/Logs/DiskMap/deletions.log.
enum Journal {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiskMap/deletions.log")
    }

    static func log(_ action: String, size: Int64, path: String) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data("date\taction\tbytes\tpath\n".utf8))
        }
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(action)\t\(size)\t\(path)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}
