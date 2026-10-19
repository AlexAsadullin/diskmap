import AppKit
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import DiskMapCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static private(set) var shared: AppDelegate!

    private var controllers: [MapWindowController] = []
    private var launchPaths: [String]
    private var openedAtLaunch = false
    private var settingsWindow: NSWindow?

    init(launchPaths: [String]) {
        self.launchPaths = launchPaths
        super.init()
        AppDelegate.shared = self
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        NotificationCenter.default.addObserver(forName: AppSettings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildMenu() }
        }
        for p in launchPaths { open(URL(fileURLWithPath: p), reusing: nil) }
        DispatchQueue.main.async {
            if self.controllers.isEmpty && !self.openedAtLaunch { self.newWindow().showWindow(nil) }
        }
        NSApp.activate(ignoringOtherApps: true)
        scheduleDebugSnapshots()
    }

    /// Development aid: DISKMAP_SNAPSHOT=/path/prefix saves the key window as PNG every few seconds,
    /// which works without Screen Recording permission.
    private func scheduleDebugSnapshots() {
        guard let prefix = ProcessInfo.processInfo.environment["DISKMAP_SNAPSHOT"] else { return }
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let view = (NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible })?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                n += 1
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)\(n).png"))
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        for url in urls { open(url, reusing: nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow().showWindow(nil) }
        return true
    }

    func windowClosed(_ c: MapWindowController) {
        controllers.removeAll { $0 === c }
    }

    // MARK: - Windows

    @discardableResult
    func newWindow() -> MapWindowController {
        let c = MapWindowController()
        let host = NSApp.keyWindow ?? controllers.last?.window
        controllers.append(c)
        if AppSettings.shared.openInTabs, let host, let w = c.window, host.tabbingIdentifier == w.tabbingIdentifier {
            host.addTabbedWindow(w, ordered: .above)
        }
        return c
    }

    /// A window with nothing in it, or a new one.
    private func emptySession(reusing session: ScanSession?) -> (ScanSession, MapWindowController?) {
        if let session, session.phase == .empty || { if case .failed = session.phase { return true }; return false }() {
            return (session, nil)
        }
        if let c = controllers.first(where: { $0.session.phase == .empty && $0.window?.isKeyWindow == true }) {
            return (c.session, c)
        }
        let c = newWindow()
        return (c.session, c)
    }

    /// Opens a folder (scan) or a saved .diskmap result.
    func open(_ url: URL, reusing session: ScanSession?) {
        let (s, c) = emptySession(reusing: session)
        if url.pathExtension == ScanArchive.fileExtension {
            s.load(url: url)
        } else {
            var isDir: ObjCBool = false
            let path = url.path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                let a = NSAlert()
                a.messageText = T("Можно сканировать только папки и тома.", "Only folders and volumes can be scanned.")
                a.informativeText = path
                a.runModal()
                return
            }
            s.startScan(path: path)
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        (c?.window ?? s.window)?.makeKeyAndOrderFront(nil)
    }

    func chooseFolder(for session: ScanSession?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = T("Сканировать", "Scan")
        panel.message = T("Выберите папку или том для сканирования", "Choose a folder or volume to scan")
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK else { return }
        for (i, url) in panel.urls.enumerated() { open(url, reusing: i == 0 ? session : nil) }
    }

    @objc func newScan(_ sender: Any?) {
        let current = (NSApp.keyWindow?.windowController as? MapWindowController)?.session
        chooseFolder(for: current)
    }

    @objc func scanHome(_ sender: Any?) {
        open(URL(fileURLWithPath: NSHomeDirectory()), reusing: (NSApp.keyWindow?.windowController as? MapWindowController)?.session)
    }

    @objc func scanStartupDisk(_ sender: Any?) {
        open(URL(fileURLWithPath: "/"), reusing: (NSApp.keyWindow?.windowController as? MapWindowController)?.session)
    }

    @objc func openResult(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ScanArchive.fileExtension) ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let current = (NSApp.keyWindow?.windowController as? MapWindowController)?.session
        for (i, url) in panel.urls.enumerated() { open(url, reusing: i == 0 ? current : nil) }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.title = T("Настройки", "Settings")
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showDeletionLog(_ sender: Any?) {
        if !FileManager.default.fileExists(atPath: Journal.url.path) {
            let a = NSAlert()
            a.messageText = T("Журнал удалений пока пуст.", "The deletion log is empty.")
            a.runModal()
            return
        }
        NSWorkspace.shared.open(Journal.url)
    }

    @objc func openFullDiskAccess(_ sender: Any?) { Permissions.openFullDiskAccessSettings() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()
        let cmd: NSEvent.ModifierFlags = .command
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let backspace = String(UnicodeScalar(NSBackspaceCharacter)!)

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            main.addItem(host)
            return host
        }

        // App
        _ = submenu("DiskMap", [
            item(T("О программе DiskMap", "About DiskMap"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(T("Настройки…", "Settings…"), #selector(showSettings(_:)), ","),
            item(T("Полный доступ к диску…", "Full Disk Access…"), #selector(openFullDiskAccess(_:))),
            .separator(),
            item(T("Скрыть DiskMap", "Hide DiskMap"), #selector(NSApplication.hide(_:)), "h"),
            item(T("Скрыть остальные", "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(T("Показать все", "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(T("Завершить DiskMap", "Quit DiskMap"), #selector(NSApplication.terminate(_:)), "q"),
        ])

        // File
        _ = submenu(T("Файл", "File"), [
            item(T("Сканировать папку / том…", "Scan Folder / Volume…"), #selector(newScan(_:)), "n"),
            item(T("Сканировать домашнюю папку", "Scan Home Folder"), #selector(scanHome(_:)), "h", [.command, .shift]),
            item(T("Сканировать загрузочный диск", "Scan Startup Disk"), #selector(scanStartupDisk(_:))),
            item(T("Пересканировать текущую папку", "Rescan Current Folder"), #selector(MapWindowController.dmRescan(_:)), "r"),
            .separator(),
            item(T("Открыть результат сканирования…", "Open Scan Result…"), #selector(openResult(_:)), "o"),
            item(T("Сохранить результат сканирования…", "Save Scan Result…"), #selector(MapWindowController.dmSave(_:)), "s"),
            item(T("Экспорт карты (PNG) или списка (CSV)…", "Export Map (PNG) or List (CSV)…"), #selector(MapWindowController.dmExport(_:)), "e", [.command, .shift]),
            .separator(),
            item(T("Закрыть", "Close"), #selector(NSWindow.performClose(_:)), "w"),
        ])

        // Edit
        _ = submenu(T("Правка", "Edit"), [
            item(T("Отменить", "Undo"), Selector(("undo:")), "z"),
            item(T("Повторить", "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(T("Вырезать", "Cut"), #selector(NSText.cut(_:)), "x"),
            item(T("Копировать", "Copy"), #selector(NSText.copy(_:)), "c"),
            item(T("Вставить", "Paste"), #selector(NSText.paste(_:)), "v"),
            item(T("Выбрать все", "Select All"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(T("В корзину", "Move to Trash"), #selector(MapWindowController.dmTrash(_:)), backspace, cmd),
            item(T("Удалить навсегда…", "Delete Permanently…"), #selector(MapWindowController.dmDeletePermanently(_:)), backspace, [.command, .option]),
            .separator(),
            item(T("Найти по имени", "Find by Name"), #selector(MapWindowController.dmFind(_:)), "f"),
            item(T("Скопировать путь", "Copy Path"), #selector(MapWindowController.dmCopyPath(_:)), "c", [.command, .option]),
            .separator(),
            item(T("Журнал удалений", "Deletion Log"), #selector(showDeletionLog(_:))),
        ])

        // View
        var depthItems = (1...10).map { d in
            item(T("Глубина \(d)", "Depth \(d)"), #selector(MapWindowController.dmDepth(_:)), d <= 9 ? "\(d)" : "", .option, tag: d)
        }
        depthItems.append(item(T("Все уровни", "All Levels"), #selector(MapWindowController.dmDepth(_:)), "0", .option, tag: 0))
        let depthMenu = NSMenuItem(title: T("Глубина", "Depth"), action: nil, keyEquivalent: "")
        depthMenu.submenu = NSMenu(title: T("Глубина", "Depth"))
        depthItems.forEach(depthMenu.submenu!.addItem)

        _ = submenu(T("Вид", "View"), [
            item(T("Приблизить к папке", "Zoom Into Folder"), #selector(MapWindowController.dmZoomIn(_:)), down, cmd),
            item(T("На уровень выше", "Up One Level"), #selector(MapWindowController.dmZoomOut(_:)), up, cmd),
            item(T("К корню", "To Root"), #selector(MapWindowController.dmZoomRoot(_:)), up, [.command, .shift]),
            .separator(),
            item(T("Увеличить", "Zoom In"), #selector(MapWindowController.dmMagnify(_:)), "+"),
            item(T("Уменьшить", "Zoom Out"), #selector(MapWindowController.dmMinify(_:)), "-"),
            item(T("Сбросить масштаб", "Actual Size"), #selector(MapWindowController.dmResetZoom(_:)), "0"),
            .separator(),
            depthMenu,
            .separator(),
            item(T("Показать инспектор", "Show Inspector"), #selector(MapWindowController.dmToggleInspector(_:)), "i"),
            item(T("Показать легенду", "Show Legend"), #selector(MapWindowController.dmToggleLegend(_:)), "l"),
            item(T("Размер: физический / логический", "Size: Physical / Logical"), #selector(MapWindowController.dmToggleSizeMode(_:)), "p", [.command, .shift]),
            .separator(),
            item(T("Полноэкранный режим", "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        // Go
        _ = submenu(T("Переход", "Go"), [
            item(T("Назад", "Back"), #selector(MapWindowController.dmBack(_:)), "["),
            item(T("Вперёд", "Forward"), #selector(MapWindowController.dmForward(_:)), "]"),
            .separator(),
            item(T("Показать в Finder", "Show in Finder"), #selector(MapWindowController.dmReveal(_:)), "r", [.command, .shift]),
            item(T("Открыть  (⌘↓ на файле)", "Open  (⌘↓ on a file)"), #selector(MapWindowController.dmOpen(_:))),
            item(T("Быстрый просмотр  (Пробел)", "Quick Look  (Space)"), #selector(MapWindowController.dmQuickLook(_:)), "y"),
        ])

        // Window
        let windowMenu = submenu(T("Окно", "Window"), [
            item(T("Свернуть", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(T("Изменить масштаб", "Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(T("Новое окно", "New Window"), #selector(newEmptyWindow(_:)), "n", [.command, .option]),
            .separator(),
            item(T("Все окна — на передний план", "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])

        // Help
        let helpMenu = submenu(T("Справка", "Help"), [
            item(T("Полный доступ к диску…", "Full Disk Access…"), #selector(openFullDiskAccess(_:))),
            item(T("Журнал удалений", "Deletion Log"), #selector(showDeletionLog(_:))),
        ])

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu.submenu
        NSApp.helpMenu = helpMenu.submenu
    }

    @objc func newEmptyWindow(_ sender: Any?) {
        newWindow().showWindow(nil)
    }
}
