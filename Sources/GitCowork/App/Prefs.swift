import Foundation

/// User settings, stored in UserDefaults. Views bind to the same keys with @AppStorage.
enum Prefs {
    enum Key {
        /// Follow macOS, or always light or dark (AppAppearance).
        static let appearance = "appearance"
        /// macOS's own key for the per-app language (AppLanguage).
        static let language = "AppleLanguages"
        static let editorApp = "editorApp"
        static let terminalApp = "terminalApp"
        static let hostOverrides = "hostOverrides"
        static let recentRepos = "recentRepos"
        /// Fetch/push refs/cowork/main about once a minute while the app is in front.
        /// (Which remote is `git config cowork.remote` in each repo; see CoworkRemote.)
        static let coworkAutoSync = "cowork.autoSync"
        /// `git fetch --all --prune` every 5 minutes while the app is in front.
        static let autoFetch = "git.autoFetch"
        /// Ask GitHub once a day whether a newer release exists.
        static let checkForUpdates = "updates.check"
        static let lastUpdateCheck = "updates.lastCheck"

        // Git, accounts, cowork
        /// Signed-in accounts (JSON; tokens are in the Keychain).
        static let accounts = "accounts"
        /// OAuth client ID entered for a self-hosted server.
        static func oauthClientID(_ host: String) -> String { "oauth.clientID.\(host)" }
        /// Inbox items already shown in the UI / sent as notifications, per repository.
        static func coworkSeen(_ repo: String) -> String { "cowork.seen.\(repo)" }
        static func coworkNotified(_ repo: String) -> String { "cowork.notified.\(repo)" }

        // View state: remembered by the views, not shown in Settings.
        static let sidebarVisible = "layout.sidebarVisible"
        /// Open or closed sidebar section, e.g. "sidebar.local".
        static func sidebarSection(_ section: SidebarSection) -> String { "sidebar." + section.rawValue }
        /// Collapsed branch folders and remotes, per repository.
        static let sidebarCollapsedByRepo = "sidebar.collapsedByRepo"
        /// Older global version of `sidebarCollapsedByRepo`; removed when saving.
        static let sidebarCollapsedFoldersOld = "sidebar.collapsedFolders"
        static let diffMode = "diff.mode"
        static let historyHiddenColumns = "history.hiddenColumns"
        static let boardAssignee = "board.assignee"
        static let reviewsFilter = "reviews.filter"
    }

    static var editorApp: String { UserDefaults.standard.string(forKey: Key.editorApp) ?? "Visual Studio Code" }
    static var terminalApp: String { UserDefaults.standard.string(forKey: Key.terminalApp) ?? "Terminal" }
    static var hostOverrides: String { UserDefaults.standard.string(forKey: Key.hostOverrides) ?? "" }

    static var coworkAutoSync: Bool { UserDefaults.standard.object(forKey: Key.coworkAutoSync) as? Bool ?? true }
    static var autoFetch: Bool { UserDefaults.standard.object(forKey: Key.autoFetch) as? Bool ?? true }
    static var checkForUpdates: Bool { UserDefaults.standard.object(forKey: Key.checkForUpdates) as? Bool ?? true }

    static var recentRepos: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.recentRepos) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(20)), forKey: Key.recentRepos) }
    }

    /// Recent repositories worth showing: still on disk and not in a temporary
    /// folder (throwaway repos from scripts and test runs).
    static var visibleRecents: [String] {
        let temp = [NSTemporaryDirectory(), "/tmp/", "/private/tmp/", "/private/var/folders/", "/var/folders/"]
        return recentRepos.filter { path in
            FileManager.default.fileExists(atPath: path) && !temp.contains { path.hasPrefix($0) }
        }
    }

    static func addRecent(_ path: String) {
        var list = recentRepos.filter { $0 != path }
        list.insert(path, at: 0)
        recentRepos = list
    }
}
