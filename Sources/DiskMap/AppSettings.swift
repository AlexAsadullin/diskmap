import AppKit
@preconcurrency import DiskMapCore

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let changed = Notification.Name("DiskMapSettingsChanged")

    private let d = UserDefaults.standard

    @Published var language: String { didSet { d.set(language, forKey: L10n.defaultsKey); L10n.reload(); notify() } }
    @Published var defaultSizeMode: SizeMode { didSet { d.set(defaultSizeMode.rawValue, forKey: "sizeMode") } }
    @Published var confirmTrash: Bool { didSet { d.set(confirmTrash, forKey: "confirmTrash") } }
    @Published var allowPermanentDelete: Bool { didSet { d.set(allowPermanentDelete, forKey: "allowPermanentDelete") } }
    @Published var openInTabs: Bool { didSet { d.set(openInTabs, forKey: "openInTabs") } }
    @Published var colorOverrides: [String: UInt32] {
        didSet { d.set(colorOverrides.mapValues { Int($0) }, forKey: "colorOverrides"); notify() }
    }
    @Published var customCategories: [CategoryDef] {
        didSet { d.set(try? JSONEncoder().encode(customCategories), forKey: "customCategories"); notify() }
    }

    private init() {
        d.register(defaults: ["confirmTrash": true, "openInTabs": true, "sizeMode": 0, L10n.defaultsKey: "system"])
        language = d.string(forKey: L10n.defaultsKey) ?? "system"
        defaultSizeMode = SizeMode(rawValue: d.integer(forKey: "sizeMode")) ?? .physical
        confirmTrash = d.bool(forKey: "confirmTrash")
        allowPermanentDelete = d.bool(forKey: "allowPermanentDelete")
        openInTabs = d.bool(forKey: "openInTabs")
        colorOverrides = (d.dictionary(forKey: "colorOverrides") as? [String: Int] ?? [:]).mapValues { UInt32($0) }
        customCategories = (d.data(forKey: "customCategories")).flatMap { try? JSONDecoder().decode([CategoryDef].self, from: $0) } ?? []
    }

    func makeCategoryTable() -> CategoryTable {
        CategoryTable(colors: colorOverrides, custom: customCategories)
    }

    private func notify() {
        NotificationCenter.default.post(name: AppSettings.changed, object: nil)
    }
}

extension RGB {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .gray
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }
}
