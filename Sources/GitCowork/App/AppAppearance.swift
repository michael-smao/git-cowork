import AppKit

/// Settings > Appearance: follow macOS, or stay light or dark regardless of it.
enum AppAppearance: String, CaseIterable {
    case system, light, dark

    static var saved: AppAppearance {
        UserDefaults.standard.string(forKey: Prefs.Key.appearance).flatMap(AppAppearance.init) ?? .system
    }

    var title: String {
        switch self {
        case .system: L("System")
        case .light: L("Light")
        case .dark: L("Dark")
        }
    }

    /// Sets it for the whole app. SwiftUI and the AppKit views both follow.
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
