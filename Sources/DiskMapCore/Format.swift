import Foundation

/// Interface language. Stored in UserDefaults under "language": "system", "ru" or "en".
public enum L10n {
    public static let defaultsKey = "language"

    public private(set) static var isRussian: Bool = resolve()

    public static func reload() { isRussian = resolve() }

    private static func resolve() -> Bool {
        switch UserDefaults.standard.string(forKey: defaultsKey) ?? "system" {
        case "ru": return true
        case "en": return false
        default: return (Locale.preferredLanguages.first ?? "en").hasPrefix("ru")
        }
    }
}

/// Picks the Russian or English string for the current interface language.
@inline(__always)
public func T(_ ru: String, _ en: String) -> String { L10n.isRussian ? ru : en }

public enum Fmt {
    /// Decimal units, like Finder: 1 KB = 1000 bytes.
    public static func bytes(_ value: Int64) -> String {
        let units = L10n.isRussian ? ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"] : ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = Double(abs(value))
        var i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        let sign = value < 0 ? "−" : ""
        if i == 0 { return "\(sign)\(Int(v)) \(units[0])" }
        let digits = v < 10 ? 2 : (v < 100 ? 1 : 0)
        var s = String(format: "%.\(digits)f", v)
        if L10n.isRussian { s = s.replacingOccurrences(of: ".", with: ",") }
        return "\(sign)\(s) \(units[i])"
    }

    public static func count(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = L10n.isRussian ? "\u{202F}" : ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "—" }
        let p = Double(part) / Double(whole) * 100
        var s = p < 1 ? String(format: "%.2f", p) : String(format: "%.1f", p)
        if L10n.isRussian { s = s.replacingOccurrences(of: ".", with: ",") }
        return s + " %"
    }

    public static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.isRussian ? "ru_RU" : "en_US")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    public static func filesWord(_ n: Int) -> String {
        guard L10n.isRussian else { return n == 1 ? "file" : "files" }
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "файл" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "файла" }
        return "файлов"
    }
}
