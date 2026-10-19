import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import DiskMapCore

extension Node: Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

struct ContentView: View {
    @ObservedObject var session: ScanSession
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            ToolbarBar(session: session)
            Divider()
            switch session.phase {
            case .empty:
                WelcomeView(session: session, error: nil)
            case .failed(let message):
                WelcomeView(session: session, error: message)
            case .scanning:
                ScanProgressView(session: session)
            case .ready:
                BreadcrumbBar(session: session)
                Divider()
                HStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        MapRepresentable(session: session)
                        if let path = session.rescanningPath {
                            RescanBanner(session: session, path: path)
                        }
                    }
                    .frame(minWidth: 400, minHeight: 300)
                    if session.showInspector {
                        Divider()
                        InspectorView(session: session)
                            .frame(width: 280)
                    }
                }
                Divider()
                StatusBar(session: session)
                if session.showLegend {
                    Divider()
                    LegendBar(session: session)
                }
            }
        }
        .id(settings.language)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { AppDelegate.shared.open(url, reusing: session) }
            }
            return true
        }
    }
}

struct MapRepresentable: NSViewRepresentable {
    let session: ScanSession

    func makeNSView(context: Context) -> MapView { MapView(session: session) }
    func updateNSView(_ view: MapView, context: Context) {}
}

// MARK: - Toolbar

struct ToolbarBar: View {
    @ObservedObject var session: ScanSession
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { AppDelegate.shared.newScan(nil) } label: {
                Label(T("Сканировать", "Scan"), systemImage: "magnifyingglass.circle")
            }
            .help(T("Сканировать папку или том (⌘N)", "Scan a folder or volume (⌘N)"))

            Divider().frame(height: 18)

            Group {
                Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                    .help(T("Назад (⌘[)", "Back (⌘[)"))
                    .disabled(!session.canGoBack)
                Button { session.zoomOut() } label: { Image(systemName: "arrow.up") }
                    .help(T("Вверх на уровень (⌘↑)", "Up one level (⌘↑)"))
                    .disabled(!session.canZoomOut)
                Button { session.zoomIn() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .help(T("Приблизить к выбранной папке (⌘↓)", "Zoom into selected folder (⌘↓)"))
                    .disabled(session.primary?.isDirectory != true)
                Button { session.stepZoom(in: true) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help(T("Увеличить (⌘+)", "Zoom in (⌘+)"))
                    .disabled(session.zoom >= ScanSession.maxZoom)
                Button { session.stepZoom(in: false) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help(T("Уменьшить (⌘−)", "Zoom out (⌘−)"))
                    .disabled(session.zoom <= 1)
            }
            .disabled(session.phase != .ready)

            Divider().frame(height: 18)

            Button { session.deleteSelection(permanently: false) } label: {
                Label(T("В корзину", "Move to Trash"), systemImage: "trash")
            }
            .help(trashHelp)
            .disabled(session.phase != .ready || !session.canDeleteSelection)

            Divider().frame(height: 18)

            Text(T("Глубина:", "Depth:")).foregroundStyle(.secondary)
            Slider(value: depthBinding, in: 1...11, step: 1)
                .frame(width: 130)
                .disabled(session.phase != .ready)
            Text(session.depthLimit == 0 ? T("Все", "All") : "\(session.depthLimit)")
                .monospacedDigit()
                .frame(width: 28, alignment: .leading)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(T("Поиск по имени", "Search by name"), text: $session.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = session.searchResults.first { session.reveal(first) } }
                if session.searching { ProgressView().controlSize(.small) }
                if !session.searchText.isEmpty {
                    Button { session.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .frame(width: 240)
            .disabled(session.phase != .ready)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .onChange(of: session.focusSearchToken) { _ in searchFocused = true }
    }

    private var trashHelp: String {
        if let n = session.primary, let reason = session.deletionBlockReason(n) { return reason }
        return T("Переместить выбранное в Корзину (⌘⌫)", "Move selection to the Trash (⌘⌫)")
    }

    private var depthBinding: Binding<Double> {
        Binding(get: { session.depthLimit == 0 ? 11 : Double(session.depthLimit) },
                set: { session.depthLimit = $0 >= 11 ? 0 : Int($0) })
    }
}

// MARK: - Breadcrumbs

struct BreadcrumbBar: View {
    @ObservedObject var session: ScanSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let crumbs = session.breadcrumbs
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, n in
                        if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Button {
                            session.navigate(to: n)
                        } label: {
                            HStack(spacing: 4) {
                                if i == 0 { Image(systemName: n.name == "/" ? "internaldrive" : "folder") }
                                Text(i == 0 ? n.path : n.displayName)
                                if i == crumbs.count - 1 { Text(Fmt.bytes(n.size(session.sizeMode))).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(i == crumbs.count - 1 ? Color.accentColor.opacity(0.15) : .clear))
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .onChange(of: session.breadcrumbs.count) { c in proxy.scrollTo(c - 1) }
        }
        .font(.system(size: 12))
    }
}

// MARK: - Status bar and legend

struct StatusBar: View {
    @ObservedObject var session: ScanSession

    var body: some View {
        HStack(spacing: 14) {
            if let root = session.root {
                item(T("Корень", "Root"), Fmt.bytes(root.size(session.sizeMode)))
                item(T("Файлов", "Files"), Fmt.count(Int(root.fileCount)))
            }
            if let v = session.volume {
                item(T("Свободно на томе", "Free on volume"), "\(Fmt.bytes(v.available)) " + T("из", "of") + " \(Fmt.bytes(v.capacity))")
            }
            item(T("Масштаб", "Zoom"), String(format: "×%.1f", session.zoom))
            Button {
                session.toggleSizeMode()
            } label: {
                item(T("Размер", "Size"), session.sizeMode.title)
            }
            .buttonStyle(.plain)
            .help(T("Переключить физический / логический размер (⌘⇧P)", "Toggle physical / logical size (⌘⇧P)"))
            if session.freedBytes != 0 {
                item(T("Освобождено", "Freed"), Fmt.bytes(session.freedBytes))
                    .foregroundStyle(.green)
            }
            if session.noAccessCount > 0 {
                Button {
                    Permissions.openFullDiskAccessSettings()
                } label: {
                    Label(T("Нет доступа: \(session.noAccessCount) папок", "No access: \(session.noAccessCount) folders"), systemImage: "lock.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help(T("Открыть настройки «Полный доступ к диску»", "Open Full Disk Access settings"))
            }
            Spacer()
            if session.savedFrom != nil {
                Text(T("Сохранённый результат от ", "Saved scan from ") + Fmt.date(session.scanDate)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func item(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title + ":").foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

struct LegendBar: View {
    @ObservedObject var session: ScanSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(entries, id: \.0) { index, def, total in
                    let hidden = session.hiddenCategories.contains(index)
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(nsColor: RGB(hex: def.hex).nsColor))
                            .frame(width: 11, height: 11)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.25)))
                        Text(def.name).strikethrough(hidden)
                        Text(Fmt.bytes(total)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(session.highlightCategory == index ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
                    .opacity(hidden ? 0.45 : 1)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { session.highlightCategory = index } else if session.highlightCategory == index { session.highlightCategory = nil }
                    }
                    .onTapGesture {
                        if hidden { session.hiddenCategories.remove(index) } else { session.hiddenCategories.insert(index) }
                    }
                    .help(T("Наведите, чтобы подсветить; щёлкните, чтобы скрыть или показать", "Hover to highlight; click to hide or show"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .font(.system(size: 11))
    }

    private var entries: [(UInt8, CategoryDef, Int64)] {
        var result: [(UInt8, CategoryDef, Int64)] = []
        for (i, def) in session.table.defs.enumerated() {
            var total = i < session.categoryTotals.count ? session.categoryTotals[i] : 0
            if def.isSpecial, let root = session.root {
                total = root.children.filter { $0.isSynthetic && Int($0.category) == i }.reduce(0) { $0 + $1.physical }
            }
            if total > 0 { result.append((UInt8(i), def, total)) }
        }
        return result.sorted { $0.2 > $1.2 }
    }
}

// MARK: - Welcome and progress

struct WelcomeView: View {
    @ObservedObject var session: ScanSession
    let error: String?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("DiskMap").font(.largeTitle.weight(.semibold))
            Text(T("Что занимает место на диске — одним взглядом", "See what takes up your disk space at a glance"))
                .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            VStack(spacing: 8) {
                bigButton(T("Домашняя папка", "Home Folder"), "house", NSHomeDirectory())
                ForEach(volumes, id: \.path) { url in
                    bigButton(volumeName(url), url.path == "/" ? "internaldrive" : "externaldrive", url.path)
                }
                HStack(spacing: 8) {
                    Button { AppDelegate.shared.chooseFolder(for: session) } label: {
                        Label(T("Выбрать папку…", "Choose Folder…"), systemImage: "folder").frame(maxWidth: .infinity)
                    }
                    Button { AppDelegate.shared.openResult(nil) } label: {
                        Label(T("Открыть результат…", "Open Result…"), systemImage: "doc").frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.large)
            }
            .frame(width: 380)
            Text(T("Можно перетащить папку или диск в это окно или на иконку в Dock.", "You can also drop a folder or disk onto this window or the Dock icon."))
                .font(.callout).foregroundStyle(.secondary)
            Button(T("Полный доступ к диску…", "Full Disk Access…")) { Permissions.openFullDiskAccessSettings() }
                .buttonStyle(.link)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var volumes: [URL] {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: [.skipHiddenVolumes]) ?? []
    }

    private func volumeName(_ url: URL) -> String {
        let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? url.lastPathComponent
        return T("Том «\(name)»", "Volume \"\(name)\"")
    }

    private func bigButton(_ title: String, _ icon: String, _ path: String) -> some View {
        Button { session.startScan(path: path) } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.large)
    }
}

struct ScanProgressView: View {
    @ObservedObject var session: ScanSession

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            if let f = session.expectedFraction {
                ProgressView(value: f).frame(width: 420)
            } else {
                ProgressView().progressViewStyle(.linear).frame(width: 420)
            }
            Text(T("Сканирование…", "Scanning…")).font(.title2.weight(.medium))
            Text(session.progress.currentPath)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(width: 520)
            HStack(spacing: 18) {
                Text(T("Файлов: ", "Files: ") + Fmt.count(session.progress.files))
                Text(T("Папок: ", "Folders: ") + Fmt.count(session.progress.folders))
                Text(T("Объём: ", "Size: ") + Fmt.bytes(session.progress.physical))
                if session.progress.noAccess > 0 {
                    Text(T("Нет доступа: ", "No access: ") + "\(session.progress.noAccess)").foregroundStyle(.orange)
                }
            }
            .monospacedDigit()
            Button(T("Отменить", "Cancel")) { session.cancelScan() }
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RescanBanner: View {
    @ObservedObject var session: ScanSession
    let path: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(T("Пересканирование ", "Rescanning ") + (path as NSString).lastPathComponent + " — " + Fmt.count(session.progress.files) + " " + Fmt.filesWord(session.progress.files))
            Button(T("Отменить", "Cancel")) { session.cancelScan() }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 10)
    }
}
