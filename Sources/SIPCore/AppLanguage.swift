import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system, en, ru, kk, pt, es, fr, de, zh, hi, ar
    public static var translated: [AppLanguage] { allCases.filter { $0 != .system } }
    public var isRightToLeft: Bool { self == .ar }
    public var nativeName: String {
        switch self {
        case .system: "System"
        case .en: "English"
        case .ru: "Русский"
        case .kk: "Қазақша"
        case .pt: "Português"
        case .es: "Español"
        case .fr: "Français"
        case .de: "Deutsch"
        case .zh: "中文"
        case .hi: "हिन्दी"
        case .ar: "العربية"
        }
    }
    public static func resolve(selection: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        if selection != .system { return selection }
        for identifier in preferredLanguages {
            let base = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased() ?? ""
            if let language = AppLanguage(rawValue: base), language != .system { return language }
        }
        return .en
    }
}
