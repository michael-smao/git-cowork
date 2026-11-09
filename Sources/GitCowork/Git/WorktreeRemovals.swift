import AppKit
import Observation

/// Worktrees being removed right now, app-wide. Removing one deletes its whole
/// folder, which can take a while (node_modules, build output). It runs in the
/// background so every tab stays usable, and each tab of the repository shows
/// the row as "Removing…" until git is done. App-wide because removing the
/// worktree a tab shows moves that tab to the main worktree first.
@MainActor
@Observable
final class WorktreeRemovals {
    static let shared = WorktreeRemovals()

    private(set) var paths: Set<String> = []

    func contains(_ path: String) -> Bool { paths.contains(path) }

    func begin(_ path: String) -> Bool { paths.insert(path).inserted }

    func end(_ path: String) { paths.remove(path) }

    /// For a failure after the tab already left the worktree, so its model has
    /// no window to show an alert in: a sheet on the front window instead.
    static func reportFailure(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
