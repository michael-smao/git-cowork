import Foundation

/// Settings > Language: follow macOS, or always English or German. Stored where
/// macOS keeps the per-app language (System Settings > General > Language &
/// Region > Applications), so the two always agree. Applies from the next launch.
enum AppLanguage: String, CaseIterable {
    case system, en, de

    static var saved: AppLanguage {
        // This app's own value only: a plain read also returns the Mac's language list.
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let languages = UserDefaults.standard.persistentDomain(forName: domain)?[Prefs.Key.language] as? [String]
        switch languages?.first?.prefix(2) {
        case "en": return .en
        case "de": return .de
        default: return .system
        }
    }

    /// The language this run of the app is showing.
    static let atLaunch = saved

    /// Each language's name in that language, so it's findable from either one.
    var title: String {
        switch self {
        case .system: L("System")
        case .en: "English"
        case .de: "Deutsch"
        }
    }

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Prefs.Key.language)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Prefs.Key.language)
        }
    }
}
