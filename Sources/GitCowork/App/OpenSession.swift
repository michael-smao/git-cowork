import AppKit
import GitCoworkCore

/// Remembers which repositories are open, in tab order, so the next launch
/// opens them again (Settings › Reopen repositories). Saved whenever a tab
/// opens or closes, and once more when quitting, before any window closes.
/// A tab showing a workspace is saved with it.
@MainActor
enum OpenSession {
    private struct Entry {
        weak var host: HostWindow?
        let target: TabTarget
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]
    /// Set while quitting: windows closing then must not shrink the saved list.
    private static var frozen = false
    /// Until the last session is reopened, windows macOS restores on its own
    /// must not overwrite the saved list with just themselves.
    private static var launching = true

    static func track(_ host: HostWindow, target: TabTarget?) {
        if let target, !target.isEmpty {
            entries[ObjectIdentifier(host)] = Entry(host: host, target: target)
        } else {
            entries[ObjectIdentifier(host)] = nil
        }
        // Next turn: the window may only now be attached (WindowAccessor).
        DispatchQueue.main.async { save() }
    }

    static func untrack(_ host: HostWindow) {
        entries[ObjectIdentifier(host)] = nil
        DispatchQueue.main.async { save() }
    }

    /// Called from applicationShouldTerminate: windows are all still there.
    static func saveForQuit() {
        save()
        frozen = true
    }

    /// The last session is open again (or there was none): save from now on.
    static func finishLaunching() {
        launching = false
        save()
    }

    /// What the open tabs show, with real paths.
    static var openTargets: Set<TabTarget> { Set(entries.values.map { real($0.target) }) }

    static func isOpen(_ target: TabTarget) -> Bool { openTargets.contains(real(target)) }

    private static func real(_ target: TabTarget) -> TabTarget {
        TabTarget(path: target.path.map(realPath), workspace: target.workspace)
    }

    /// Open tabs in tab order (front window's group first), and the selected one.
    static func save() {
        guard !frozen, !launching else { return }
        var byWindow: [ObjectIdentifier: TabTarget] = [:]
        for entry in entries.values {
            if let w = entry.host?.window { byWindow[ObjectIdentifier(w)] = real(entry.target) }
        }
        var order: [TabTarget] = []
        var seenWindows = Set<ObjectIdentifier>()
        for window in NSApp.orderedWindows + NSApp.windows where !seenWindows.contains(ObjectIdentifier(window)) {
            for tab in window.tabbedWindows ?? [window] where seenWindows.insert(ObjectIdentifier(tab)).inserted {
                if let target = byWindow[ObjectIdentifier(tab)], !order.contains(target) { order.append(target) }
            }
        }
        let front = (NSApp.keyWindow ?? NSApp.mainWindow).flatMap { byWindow[ObjectIdentifier($0)] } ?? order.first
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(order), forKey: Prefs.Key.openTabs)
        defaults.set(front.flatMap { try? JSONEncoder().encode($0) }, forKey: Prefs.Key.openTabsSelected)
        // Older versions read just the paths. Also how the next launch tells
        // whether one of them saved after this (SessionRestore.savedTabs).
        let paths = SessionRestore.uniquePaths(order)
        defaults.set(paths, forKey: Prefs.Key.openRepos)
        defaults.set(front?.path ?? paths.first, forKey: Prefs.Key.openReposSelected)
    }

    /// The tabs saved at the last quit, or the paths an older version saved after that.
    static var saved: (tabs: [TabTarget], selected: TabTarget?) {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        return SessionRestore.savedTabs(
            tabs: defaults.data(forKey: Prefs.Key.openTabs).flatMap { try? decoder.decode([TabTarget].self, from: $0) },
            selectedTab: defaults.data(forKey: Prefs.Key.openTabsSelected).flatMap { try? decoder.decode(TabTarget.self, from: $0) },
            paths: defaults.stringArray(forKey: Prefs.Key.openRepos) ?? [],
            selectedPath: defaults.string(forKey: Prefs.Key.openReposSelected))
    }

    /// The window showing `path`, to bring it to the front after reopening.
    static func window(for path: String) -> NSWindow? {
        entries.values.first { $0.target.path == path }?.host?.window
    }

    /// Another tab showing `path`, with or without a workspace.
    static func window(showing path: String, except own: NSWindow?) -> NSWindow? {
        let real = realPath(path)
        return entries.values.lazy
            .filter { $0.target.path.map(realPath) == real }
            .compactMap { $0.host?.window }
            .first { $0 !== own }
    }

    /// A tab already showing the workspace.
    static func window(showingWorkspace id: String) -> NSWindow? {
        entries.values.first { $0.target.workspace == id }?.host?.window
    }
}
