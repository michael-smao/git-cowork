import AppKit
import GitCoworkCore

/// Remembers which repositories are open, in tab order, so the next launch
/// opens them again (Settings › Reopen repositories). Saved whenever a tab
/// opens or closes, and once more when quitting, before any window closes.
@MainActor
enum OpenSession {
    private struct Entry {
        weak var host: HostWindow?
        let path: String
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]
    /// Set while quitting: windows closing then must not shrink the saved list.
    private static var frozen = false
    /// Until the last session is reopened, windows macOS restores on its own
    /// must not overwrite the saved list with just themselves.
    private static var launching = true

    static func track(_ host: HostWindow, path: String?) {
        if let path { entries[ObjectIdentifier(host)] = Entry(host: host, path: path) } else { entries[ObjectIdentifier(host)] = nil }
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

    /// Open repositories in tab order (front window's group first), and the selected one.
    static func save() {
        guard !frozen, !launching else { return }
        var byWindow: [ObjectIdentifier: String] = [:]
        for entry in entries.values {
            if let w = entry.host?.window { byWindow[ObjectIdentifier(w)] = realPath(entry.path) }
        }
        var order: [String] = []
        var seenWindows = Set<ObjectIdentifier>()
        for window in NSApp.orderedWindows + NSApp.windows where !seenWindows.contains(ObjectIdentifier(window)) {
            for tab in window.tabbedWindows ?? [window] where seenWindows.insert(ObjectIdentifier(tab)).inserted {
                if let path = byWindow[ObjectIdentifier(tab)], !order.contains(path) { order.append(path) }
            }
        }
        let front = (NSApp.keyWindow ?? NSApp.mainWindow).flatMap { byWindow[ObjectIdentifier($0)] }
        UserDefaults.standard.set(order, forKey: Prefs.Key.openRepos)
        UserDefaults.standard.set(front ?? order.first, forKey: Prefs.Key.openReposSelected)
    }

    static var saved: (paths: [String], selected: String?) {
        (UserDefaults.standard.stringArray(forKey: Prefs.Key.openRepos) ?? [],
         UserDefaults.standard.string(forKey: Prefs.Key.openReposSelected))
    }

    /// The window showing `path`, to bring it to the front after reopening.
    static func window(for path: String) -> NSWindow? {
        entries.values.first { $0.path == path }?.host?.window
    }
}
