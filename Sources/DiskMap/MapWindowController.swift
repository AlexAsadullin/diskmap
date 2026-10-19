import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
@preconcurrency import DiskMapCore

/// One window (or tab) per scan. Handles the window-level menu commands.
@MainActor
final class MapWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let session = ScanSession()
    private var bag = Set<AnyCancellable>()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 820, height: 520)
        window.tabbingIdentifier = "DiskMap"
        window.tabbingMode = AppSettings.shared.openInTabs ? .preferred : .disallowed
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: ContentView(session: session))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1440, height: 900))
        if let screen = NSScreen.main?.visibleFrame, screen.width < 1440 || screen.height < 900 {
            window.setFrame(screen.insetBy(dx: 20, dy: 20), display: false)
        }
        window.center()
        super.init(window: window)
        window.delegate = self
        session.window = window
        session.$root.combineLatest(session.$phase)
            .sink { [weak self] _, _ in
                DispatchQueue.main.async { self?.window?.title = self?.session.title ?? "DiskMap" }
            }
            .store(in: &bag)
        window.title = "DiskMap"
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { session.undoManager }

    func windowWillClose(_ notification: Notification) {
        session.cancelScan()
        AppDelegate.shared.windowClosed(self)
    }

    // MARK: - Commands

    private var ready: Bool { session.phase == .ready }
    private var editingText: Bool { window?.firstResponder is NSText }

    @objc func dmRescan(_ sender: Any?) { session.rescan() }

    @objc func dmSave(_ sender: Any?) {
        guard let window, let root = session.root else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ScanArchive.fileExtension) ?? .data]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "\(root.displayName == "/" ? "Disk" : root.displayName) \(stamp.string(from: Date())).\(ScanArchive.fileExtension)"
        panel.beginSheetModal(for: window) { [session] r in
            guard r == .OK, let url = panel.url else { return }
            do { try session.save(to: url) } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc func dmExport(_ sender: Any?) {
        guard let window, let view = session.viewNode else { return }
        let panel = NSSavePanel()
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: [T("Карта (PNG)", "Map (PNG)"), T("Список (CSV)", "List (CSV)")])
        let label = NSTextField(labelWithString: T("Формат:", "Format:"))
        let box = NSStackView(views: [label, popup])
        box.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = box
        let base = view.displayName == "/" ? "Disk" : view.displayName
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = base + ".png"
        popup.target = self
        popup.action = #selector(exportFormatChanged(_:))
        exportPanel = panel
        panel.beginSheetModal(for: window) { [weak self, session] r in
            self?.exportPanel = nil
            guard r == .OK, let url = panel.url else { return }
            do {
                if popup.indexOfSelectedItem == 1 { try session.exportCSV(to: url) } else {
                    let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    try session.exportPNG(to: url, dark: dark)
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private weak var exportPanel: NSSavePanel?

    @objc private func exportFormatChanged(_ sender: NSPopUpButton) {
        guard let panel = exportPanel else { return }
        let csv = sender.indexOfSelectedItem == 1
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .png]
        let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = name + (csv ? ".csv" : ".png")
    }

    @objc func dmTrash(_ sender: Any?) { session.deleteSelection(permanently: false) }
    @objc func dmDeletePermanently(_ sender: Any?) { session.deleteSelection(permanently: true) }
    @objc func dmFind(_ sender: Any?) { session.focusSearchToken += 1 }
    @objc func dmCopyPath(_ sender: Any?) { Actions.copyPaths(session.selection.isEmpty ? [session.viewNode].compactMap { $0 } : session.selection) }
    @objc func dmZoomIn(_ sender: Any?) { session.zoomIn() }
    @objc func dmZoomOut(_ sender: Any?) { session.zoomOut() }
    @objc func dmZoomRoot(_ sender: Any?) { session.zoomToRoot() }
    @objc func dmMagnify(_ sender: Any?) { session.stepZoom(in: true) }
    @objc func dmMinify(_ sender: Any?) { session.stepZoom(in: false) }
    @objc func dmResetZoom(_ sender: Any?) { session.resetZoom() }
    @objc func dmDepth(_ sender: NSMenuItem) { session.depthLimit = sender.tag }
    @objc func dmToggleInspector(_ sender: Any?) { session.showInspector.toggle() }
    @objc func dmToggleLegend(_ sender: Any?) { session.showLegend.toggle() }
    @objc func dmToggleSizeMode(_ sender: Any?) { session.toggleSizeMode() }
    @objc func dmBack(_ sender: Any?) { session.goBack() }
    @objc func dmForward(_ sender: Any?) { session.goForward() }
    @objc func dmReveal(_ sender: Any?) { Actions.revealInFinder(session.selection.isEmpty ? [session.viewNode].compactMap { $0 } : session.selection) }
    @objc func dmOpen(_ sender: Any?) {
        for n in session.selection where !n.isSynthetic { NSWorkspace.shared.open(URL(fileURLWithPath: n.path)) }
    }
    @objc func dmQuickLook(_ sender: Any?) { session.mapView?.toggleQuickLook() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let sel = item.action
        let hasSelection = !session.selection.isEmpty
        switch sel {
        case #selector(dmRescan(_:)):
            return ready && !session.isBusy
        case #selector(dmSave(_:)), #selector(dmExport(_:)), #selector(dmFind(_:)), #selector(dmResetZoom(_:)), #selector(dmToggleSizeMode(_:)):
            return ready
        case #selector(dmTrash(_:)):
            return ready && !editingText && session.canDeleteSelection
        case #selector(dmDeletePermanently(_:)):
            item.isHidden = !AppSettings.shared.allowPermanentDelete
            return ready && !editingText && session.canDeleteSelection && AppSettings.shared.allowPermanentDelete
        case #selector(dmCopyPath(_:)), #selector(dmReveal(_:)):
            return ready
        case #selector(dmZoomIn(_:)):
            let n = session.primary
            item.title = n.map { !$0.isDirectory } == true ? T("Открыть файл", "Open File") : T("Приблизить к папке", "Zoom Into Folder")
            return ready && !editingText && n != nil && n?.isSynthetic == false
        case #selector(dmZoomOut(_:)), #selector(dmZoomRoot(_:)):
            return ready && !editingText && session.canZoomOut
        case #selector(dmMagnify(_:)):
            return ready && session.zoom < ScanSession.maxZoom
        case #selector(dmMinify(_:)):
            return ready && session.zoom > 1
        case #selector(dmDepth(_:)):
            item.state = session.depthLimit == item.tag ? .on : .off
            return ready
        case #selector(dmToggleInspector(_:)):
            item.title = session.showInspector ? T("Скрыть инспектор", "Hide Inspector") : T("Показать инспектор", "Show Inspector")
            return ready
        case #selector(dmToggleLegend(_:)):
            item.title = session.showLegend ? T("Скрыть легенду", "Hide Legend") : T("Показать легенду", "Show Legend")
            return ready
        case #selector(dmBack(_:)):
            return ready && session.canGoBack
        case #selector(dmForward(_:)):
            return ready && session.canGoForward
        case #selector(dmOpen(_:)), #selector(dmQuickLook(_:)):
            return ready && hasSelection
        default:
            return true
        }
    }
}
