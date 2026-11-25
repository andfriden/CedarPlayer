import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case ru
    case en

    var id: String { rawValue }

    var code: String? {
        switch self {
        case .system: return nil
        case .ru: return "ru"
        case .en: return "en"
        }
    }

    var title: String {
        switch self {
        case .system: return L10n.string("Системный")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

enum L10n {
    static var selected: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .system
    }

    static var resolvedCode: String {
        if let code = selected.code { return code }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.lowercased().hasPrefix("ru") ? "ru" : "en"
    }

    static var locale: Locale { Locale(identifier: resolvedCode) }

    private static let bundleCache = NSCache<NSString, Bundle>()

    static var bundle: Bundle {
        let code = resolvedCode
        if let cached = bundleCache.object(forKey: code as NSString) { return cached }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            bundleCache.setObject(.main, forKey: code as NSString)
            return .main
        }
        bundleCache.setObject(bundle, forKey: code as NSString)
        return bundle
    }

    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }
}
