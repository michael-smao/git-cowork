import AppKit
import GitCoworkCore

/// Remembers which repositories are open, in tab order, so the next launch
/// opens them again (Settings › Reopen repositories). Saved whenever a tab
/// opens or closes, and once more when quitting, before any window closes.
/// A tab showing a workspace is saved with it.
///
/// Closing a tab forgets it. Closing the last window doesn't: its tabs stay
/// saved, and the next window shows them again (`takeClosedWindow`).
@MainActor
enum OpenSession {
    private struct Entry {
        weak var host: HostWindow?
        /// Nil in a window that shows no repository or workspace yet.
        let target: TabTarget?
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]
    /// Set while quitting: windows closing then must not shrink the saved list.
    private static var frozen = false
    /// Until the last session is reopened, windows macOS restores on its own
    /// must not overwrite the saved list with just themselves. Also while a
    /// new window reopens the tabs of the last one that was closed.
    private static var restoring = true
    /// The last window was closed, and no repository has been opened since.
    private static var lastWindowClosed = false

    static func track(_ host: HostWindow, target: TabTarget?) {
        entries[ObjectIdentifier(host)] = Entry(host: host, target: target.flatMap { $0.isEmpty ? nil : $0 })
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
    static func finishRestoring() {
        restoring = false
        save()
    }

    /// The tabs of the last window, when it was closed and no repository has
    /// been opened since: the next window shows them again. Saving then waits
    /// for `finishRestoring`, as at launch.
    static func takeClosedWindow() -> (tabs: [TabTarget], selected: TabTarget?)? {
        guard lastWindowClosed, !restoring, !frozen, Prefs.reopenRepos else { return nil }
        lastWindowClosed = false
        restoring = true
        return saved
    }

    /// No window is open and none is on its way: the Dock icon opens one.
    static var hasNoWindow: Bool {
        entries = entries.filter { $0.value.host != nil }
        return entries.isEmpty && !restoring && !frozen
    }

    /// What the open tabs show, with real paths.
    static var openTargets: Set<TabTarget> { Set(entries.values.compactMap(\.target).map(real)) }

    static func isOpen(_ target: TabTarget) -> Bool { openTargets.contains(real(target)) }

    private static func real(_ target: TabTarget) -> TabTarget {
        TabTarget(path: target.path.map(realPath), workspace: target.workspace)
    }

    /// Open tabs in tab order (front window's group first), and the selected one.
    static func save() {
        guard !frozen, !restoring else { return }
        entries = entries.filter { $0.value.host != nil }
        var byWindow: [ObjectIdentifier: TabTarget] = [:]
        for entry in entries.values {
            if let w = entry.host?.window, let target = entry.target { byWindow[ObjectIdentifier(w)] = real(target) }
        }
        var order: [TabTarget] = []
        var seenWindows = Set<ObjectIdentifier>()
        for window in NSApp.orderedWindows + NSApp.windows where !seenWindows.contains(ObjectIdentifier(window)) {
            for tab in window.tabbedWindows ?? [window] where seenWindows.insert(ObjectIdentifier(tab)).inserted {
                if let target = byWindow[ObjectIdentifier(tab)], !order.contains(target) { order.append(target) }
            }
        }
        // The last window is closed (the red button closes all of its tabs at
        // once). As when quitting, its tabs stay saved, for the next window
        // or the next launch. A window showing nothing yet doesn't end that;
        // the next repository that is opened does.
        if entries.isEmpty { lastWindowClosed = true }
        if lastWindowClosed && order.isEmpty { return }
        lastWindowClosed = false
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
        entries.values.first { $0.target?.path == path }?.host?.window
    }

    /// Another tab showing `path`, with or without a workspace.
    static func window(showing path: String, except own: NSWindow?) -> NSWindow? {
        let real = realPath(path)
        return entries.values.lazy
            .filter { $0.target?.path.map(realPath) == real }
            .compactMap { $0.host?.window }
            .first { $0 !== own }
    }

    /// A tab already showing the workspace.
    static func window(showingWorkspace id: String) -> NSWindow? {
        entries.values.first { $0.target?.workspace == id }?.host?.window
    }
}
