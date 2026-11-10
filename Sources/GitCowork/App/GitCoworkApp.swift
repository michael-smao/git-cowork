import AppKit
import GitCoworkCore
import SwiftUI

@main
struct GitCoworkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window per worktree. Windows open as tabs of each other.
        WindowGroup("git-cowork", id: "repo", for: String.self) { $path in
            RepoWindow(path: $path)
        }
        // Folders from `open -a git-cowork <dir>`, the command line, or the Dock icon.
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1440, height: 880)
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }
        // Only the height can change; the form scrolls inside.
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run straight from `swift run` (no app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = true
        AppAppearance.saved.apply()
        _ = GitRunner.shared   // start resolving the login shell PATH early
        DeveloperToolsCheck.runAtLaunch()
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        CoworkSelfTest.runIfRequested()
        UndoSelfTest.runIfRequested()
        GitActionsSelfTest.runIfRequested()
        UpdaterSelfTest.runIfRequested()
        #endif
        LaunchFolders.openFromCommandLine()
        Updater.shared.startAutomaticChecks()
    }

    /// Before any window closes: remember which repositories were open.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        OpenSession.saveForQuit()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Credentials.shared.stop()   // no token stays in memory after quitting
    }
}

/// Things the focused window can do; used by menu commands.
struct WindowActions {
    let open: (String) -> Void
    let showClone: () -> Void
}

extension FocusedValues {
    struct RepoModelKey: FocusedValueKey { typealias Value = RepoModel }
    struct WindowActionsKey: FocusedValueKey { typealias Value = WindowActions }

    var repoModel: RepoModel? {
        get { self[RepoModelKey.self] }
        set { self[RepoModelKey.self] = newValue }
    }

    var windowActions: WindowActions? {
        get { self[WindowActionsKey.self] }
        set { self[WindowActionsKey.self] = newValue }
    }
}

/// The same actions for views inside the window (toolbar repository menu).
private struct WindowActionsEnvironmentKey: EnvironmentKey {
    static let defaultValue: WindowActions? = nil
}

extension EnvironmentValues {
    var windowActions: WindowActions? {
        get { self[WindowActionsEnvironmentKey.self] }
        set { self[WindowActionsEnvironmentKey.self] = newValue }
    }
}

/// `GitCowork /path/to/repo` from a terminal. AppKit swallows folder
/// arguments and then SwiftUI opens no window, so open one ourselves.
@MainActor
enum LaunchFolders {
    static var pending: [String] = []
    /// Clone was chosen with no window open; the next empty window shows the clone sheet.
    static var pendingClone = false

    /// All folders from the command line. The first window to appear takes them
    /// all, so later ⌘T / New Window never pick up leftovers.
    static func takeAll() -> [String] {
        defer { pending = [] }
        return pending
    }

    /// Which of `pending` comes to the front: the tab that was in front at
    /// the last quit, or the last folder from the command line.
    static var front: String?
    /// Repositories opening as background tabs at launch. Their windows load
    /// the repository only when first selected, so a launch with many tabs
    /// loads one, not all of them at once.
    private static var background: Set<String> = []

    static func opensInBackground(_ path: String) -> Bool { background.contains(path) }
    static func markBackground(_ path: String) { background.insert(path) }

    /// All tabs are there: from now on tabs load right away, and the session is saved again.
    static func finishRestore() {
        background = []
        OpenSession.finishLaunching()
    }

    /// Name and folder for a tab whose repository hasn't loaded yet, read
    /// from the files alone: the folder name, or for a linked worktree the
    /// main repository's name plus the worktree's folder.
    static func tabLabel(for path: String) -> RepoTabLabel {
        let folder = (path as NSString).lastPathComponent
        let gitFile = (path as NSString).appendingPathComponent(".git")
        if let contents = try? String(contentsOfFile: gitFile, encoding: .utf8),
           let main = WorktreeLink.mainWorktree(gitFile: contents, worktree: path) {
            return RepoTabLabel(name: (main as NSString).lastPathComponent, worktree: folder)
        }
        return RepoTabLabel(name: folder, worktree: nil)
    }

    /// At launch: the repositories open at the last quit (Settings › Reopen
    /// repositories), then folders from the command line, as tabs.
    static func openFromCommandLine() {
        let commandLine = CommandLine.arguments.dropFirst().filter { arg in
            !arg.hasPrefix("-") && isDirectory(arg)
        }.map { realPath($0) }
        let saved: (paths: [String], selected: String?) = Prefs.reopenRepos ? OpenSession.saved : ([], nil)
        // A moment for SwiftUI's first window and anything macOS restores itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let plan = SessionRestore.plan(saved: saved.paths.map { realPath($0) }, selected: saved.selected.map { realPath($0) },
                                           commandLine: commandLine, alreadyOpen: OpenRepos.paths, exists: isDirectory)
            guard !plan.open.isEmpty else {
                OpenSession.finishLaunching()
                return
            }
            pending = plan.open
            front = plan.select
            // The first, empty window takes them: the front one here, the rest as background tabs.
            NotificationCenter.default.post(name: .launchFoldersPending, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !pending.isEmpty {
                    // No empty window (macOS restored repositories): a new tab next to them.
                    WindowAccessor.setPendingParent(NSApp.orderedWindows.first { $0.isVisible && $0.tabbingIdentifier == WindowChrome.tabbingIdentifier })
                    newWindow()
                }
                // The window that takes them calls finishRestore once all tabs are
                // there. Should none take them, saving must not stay off.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finishRestore() }
            }
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Same as File > New Window, which is how SwiftUI creates WindowGroup windows.
    static func newWindow() {
        for item in NSApp.mainMenu?.items ?? [] {
            guard let menu = item.submenu,
                  let i = menu.items.firstIndex(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }) else { continue }
            menu.performActionForItem(at: i)
            return
        }
    }
}

extension Notification.Name {
    /// Folders from the command line are waiting in `LaunchFolders.pending`.
    static let launchFoldersPending = Notification.Name("gitcowork.launchFoldersPending")
}
