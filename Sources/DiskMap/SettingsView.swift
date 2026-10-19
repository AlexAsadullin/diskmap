import SwiftUI
@preconcurrency import DiskMapCore

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TabView {
            general.tabItem { Label(T("Основные", "General"), systemImage: "gearshape") }
            CategorySettings(settings: settings).tabItem { Label(T("Категории", "Categories"), systemImage: "paintpalette") }
        }
        .padding(16)
        .frame(width: 600, height: 520)
        .id(settings.language)
    }

    private var general: some View {
        Form {
            Picker(T("Язык интерфейса", "Language"), selection: $settings.language) {
                Text(T("Системный", "System")).tag("system")
                Text("Русский").tag("ru")
                Text("English").tag("en")
            }
            Picker(T("Размер по умолчанию", "Default size"), selection: $settings.defaultSizeMode) {
                Text(T("Физический (место на диске, как du)", "Physical (disk usage, like du)")).tag(SizeMode.physical)
                Text(T("Логический (размер содержимого)", "Logical (content size)")).tag(SizeMode.logical)
            }
            Toggle(T("Открывать сканирования во вкладках", "Open scans in tabs"), isOn: $settings.openInTabs)
            Divider()
            Toggle(T("Спрашивать перед перемещением в Корзину", "Confirm before moving to the Trash"), isOn: $settings.confirmTrash)
            Toggle(T("Разрешить окончательное удаление мимо Корзины (⌘⌥⌫)", "Allow permanent deletion bypassing the Trash (⌘⌥⌫)"), isOn: $settings.allowPermanentDelete)
            Text(T("Окончательное удаление всегда требует подтверждения.", "Permanent deletion always asks for confirmation."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(T("Полный доступ к диску…", "Full Disk Access…")) { Permissions.openFullDiskAccessSettings() }
                Button(T("Журнал удалений", "Deletion Log")) { NSWorkspace.shared.open(Journal.url) }
                    .disabled(!FileManager.default.fileExists(atPath: Journal.url.path))
            }
        }
    }
}

private struct CategorySettings: View {
    @ObservedObject var settings: AppSettings

    private var table: CategoryTable { settings.makeCategoryTable() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                Section(T("Встроенные", "Built-in")) {
                    ForEach(CategoryTable.builtins) { def in
                        HStack {
                            ColorPicker("", selection: colorBinding(def), supportsOpacity: false).labelsHidden().frame(width: 44)
                            VStack(alignment: .leading) {
                                Text(def.name)
                                if !def.patterns.isEmpty {
                                    Text(def.patterns.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let other = clash(def.id) {
                                Label(T("Цвет как у «\(other)»", "Same colour as \"\(other)\""), systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if settings.colorOverrides[def.id] != nil {
                                Button(T("Сбросить", "Reset")) { settings.colorOverrides[def.id] = nil }.controlSize(.small)
                            }
                        }
                    }
                }
                Section(T("Свои категории", "Custom categories")) {
                    ForEach(settings.customCategories.indices, id: \.self) { i in
                        HStack {
                            ColorPicker("", selection: customColor(i), supportsOpacity: false).labelsHidden().frame(width: 44)
                            TextField(T("Название", "Name"), text: customName(i)).frame(width: 140)
                            TextField(T("Путь или шаблон имени папки", "Path or folder name pattern"), text: customPattern(i))
                            if let other = clash(settings.customCategories[i].id) {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                    .help(T("Цвет как у «\(other)»", "Same colour as \"\(other)\""))
                            }
                            Button { settings.customCategories.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button {
                        settings.customCategories.append(CategoryDef(
                            id: "custom.\(UUID().uuidString)", nameRU: T("Новая категория", "New category"), nameEN: T("Новая категория", "New category"),
                            hex: UInt32.random(in: 0x202020...0xE0E0E0), patterns: [], isCustom: true))
                    } label: {
                        Label(T("Добавить категорию", "Add category"), systemImage: "plus")
                    }
                }
            }
            Text(T("Шаблон без «/» сравнивается с именем папки (например, «Steam*»); с «/» — с полным путём (например, «~/Projects» или «/Volumes/*/Backups»). Свои категории важнее встроенных.",
                   "A pattern without \"/\" matches folder names (e.g. \"Steam*\"); with \"/\" it matches full paths (e.g. \"~/Projects\" or \"/Volumes/*/Backups\"). Custom categories take precedence over built-in ones."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Name of another category that already uses this category's colour.
    private func clash(_ id: String) -> String? {
        let defs = table.defs
        guard let me = defs.first(where: { $0.id == id }) else { return nil }
        return defs.first { $0.id != id && $0.hex == me.hex }?.name
    }

    private func colorBinding(_ def: CategoryDef) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: RGB(hex: settings.colorOverrides[def.id] ?? def.hex).nsColor) },
            set: { settings.colorOverrides[def.id] = RGB(NSColor($0)).hex })
    }

    private func customColor(_ i: Int) -> Binding<Color> {
        Binding(
            get: { settings.customCategories.indices.contains(i) ? Color(nsColor: RGB(hex: settings.customCategories[i].hex).nsColor) : .gray },
            set: { c in if settings.customCategories.indices.contains(i) { settings.customCategories[i].hex = RGB(NSColor(c)).hex } })
    }

    private func customName(_ i: Int) -> Binding<String> {
        Binding(
            get: { settings.customCategories.indices.contains(i) ? settings.customCategories[i].nameRU : "" },
            set: { s in
                guard settings.customCategories.indices.contains(i) else { return }
                settings.customCategories[i].nameRU = s
                settings.customCategories[i].nameEN = s
            })
    }

    private func customPattern(_ i: Int) -> Binding<String> {
        Binding(
            get: { settings.customCategories.indices.contains(i) ? settings.customCategories[i].patterns.joined(separator: ", ") : "" },
            set: { s in
                guard settings.customCategories.indices.contains(i) else { return }
                settings.customCategories[i].patterns = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            })
    }
}
