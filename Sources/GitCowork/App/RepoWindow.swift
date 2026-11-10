import AppKit
import SwiftUI

/// One window (tab). Shows the welcome screen until a repo is chosen.
struct RepoWindow: View {
    @Binding var path: String?
    @State private var showClone = false
    @State private var dropTargeted = false
    @State private var host = HostWindow()
    /// A background tab from the launch: loads its repository once selected.
    @State private var waitsUntilSelected: Bool
    @Environment(\.openWindow) private var openWindow

    init(path: Binding<String?>) {
        _path = path
        _waitsUntilSelected = State(initialValue: path.wrappedValue.map(LaunchFolders.opensInBackground) ?? false)
    }

    var body: some View {
        Group {
            if let path, waitsUntilSelected {
                UnloadedTab(path: path)
            } else if let path {
                RepoContainer(path: path, openHere: openHere, openInNewTab: openTab, close: { self.path = nil })
                    .id(path)
            } else {
                WelcomeView(open: { open($0) }, clone: { showClone = true })
            }
        }
        .environment(\.windowActions, actions)
        .frame(minWidth: 900, minHeight: 500)
        .background(WindowAccessor(host: host))
        // Remembered for the next launch (OpenSession).
        .onAppear { OpenSession.track(host, path: path) }
        .onChange(of: path) { _, new in OpenSession.track(host, path: new) }
        .onDisappear { OpenSession.untrack(host) }
        // Only an empty (welcome) window takes `open -a git-cowork <dir>`;
        // windows showing a repo decline, so SwiftUI opens a new tab instead.
        .handlesExternalEvents(preferring: path == nil ? ["*"] : [], allowing: path == nil ? ["*"] : [])
        .onAppear {
            if path == nil { openLaunchFolders() }
            if LaunchFolders.pendingClone {
                LaunchFolders.pendingClone = false
                showClone = true
            }
        }
        // The first window can appear before the command line is read.
        .onReceive(NotificationCenter.default.publisher(for: .launchFoldersPending)) { _ in
            if path == nil { openLaunchFolders() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Selected for real: placed in its tab group (visible again) and in front there.
            guard waitsUntilSelected, let window = host.window, note.object as? NSWindow === window,
                  window.alphaValue > 0, window.tabGroup?.selectedWindow.map({ $0 === window }) ?? true else { return }
            waitsUntilSelected = false
        }
        .onOpenURL { url in
            if url.isFileURL { open(url.path) }
        }
        // Drop a folder anywhere: opens here when empty, else in a new tab.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.hasDirectoryPath) ?? urls.first else { return false }
            open(url.path)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(Theme.Space.s)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showClone) {
            CloneSheet { open($0) }
        }
        .focusedSceneValue(\.windowActions, actions)
    }

    private var actions: WindowActions {
        WindowActions(open: { open($0) }, showClone: { showClone = true })
    }

    /// At launch (last session, command line): the front repository opens
    /// here right away; the others join as background tabs in their order,
    /// one after another, without coming to the front or loading yet.
    private func openLaunchFolders() {
        let folders = LaunchFolders.takeAll()
        guard !folders.isEmpty else { return }
        let wanted = LaunchFolders.front.flatMap(folders.firstIndex(of:)) ?? 0
        Task {
            var resolved: [String?] = []
            for folder in folders { resolved.append(await RepoLocator.resolve(folder)) }
            // The front one, or the first that is still a repository.
            let order = [wanted] + resolved.indices.filter { $0 != wanted }
            guard let frontIndex = order.first(where: { resolved[$0] != nil }), let front = resolved[frontIndex] else {
                LaunchFolders.finishRestore()
                return
            }
            if path == nil { path = front } else { openTab(front) }
            // Where each tab goes: before the ones that come later in the saved order.
            var placed: [Int] = [frontIndex]
            for index in resolved.indices where index != frontIndex {
                guard let folder = resolved[index], !OpenRepos.isOpen(folder) else { continue }
                if await openBackgroundTab(folder, at: placed.filter { $0 < index }.count) { placed.append(index) }
            }
            LaunchFolders.finishRestore()
        }
    }

    /// Opens `p` as a tab at `index` of this window's group, behind this one.
    /// Returns once it is there (false if no window came within 2 seconds).
    private func openBackgroundTab(_ p: String, at index: Int) async -> Bool {
        guard let parent = host.window else { return false }
        return await withCheckedContinuation { continuation in
            WindowAccessor.setPendingBackground(parent: parent, index: index) { continuation.resume(returning: $0) }
            LaunchFolders.markBackground(p)
            openWindow(id: "repo", value: p)
        }
    }

    /// Opens a repo here if this window is empty, otherwise in a new tab.
    private func open(_ chosen: String) {
        Task {
            guard let resolved = await RepoLocator.resolve(chosen) else {
                let alert = NSAlert()
                alert.messageText = L("Not a git repository")
                alert.informativeText = chosen
                alert.runModal()
                return
            }
            if path == nil { path = resolved } else { openTab(resolved) }
        }
    }

    /// Switches this window to another worktree, unless that worktree is
    /// already open in another tab: then that tab comes to the front.
    /// If the folder this window shows is gone or being removed, the window
    /// closes once the other tab is in front, rather than staying on a
    /// deleted folder.
    private func openHere(_ p: String) {
        guard OpenRepos.isOpen(p) else { path = p; return }
        openTab(p)
        if let current = path,
           WorktreeRemovals.shared.contains(current) || !FileManager.default.fileExists(atPath: current) {
            let window = host.window
            DispatchQueue.main.async { window?.close() }
        }
    }

    /// New tab next to this window. SwiftUI brings an existing window to the
    /// front when one already shows `p`.
    private func openTab(_ p: String) {
        WindowAccessor.setPendingParent(NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.orderedWindows.first { $0.isVisible && $0.tabbingIdentifier == WindowChrome.tabbingIdentifier })
        openWindow(id: "repo", value: p)
    }
}

/// Worktree paths currently shown in a window, so switching to one that's
/// already open focuses its tab instead of opening it twice.
@MainActor
enum OpenRepos {
    private static var counts: [String: Int] = [:]

    /// Every open path (resolved), for not opening a restored one twice.
    static var paths: Set<String> { Set(counts.keys) }

    static func isOpen(_ path: String) -> Bool { counts[realPath(path), default: 0] > 0 }
    static func add(_ path: String) { counts[realPath(path), default: 0] += 1 }
    static func remove(_ path: String) {
        let key = realPath(path)
        let n = counts[key, default: 0] - 1
        counts[key] = n > 0 ? n : nil
    }
}

/// Creates the model for a worktree and keeps it for the window's lifetime.
private struct RepoContainer: View {
    @State private var model: RepoModel
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void
    let close: () -> Void

    private let path: String

    init(path: String, openHere: @escaping (String) -> Void, openInNewTab: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.path = path
        _model = State(initialValue: RepoModel(root: URL(fileURLWithPath: path)))
        self.openHere = openHere
        self.openInNewTab = openInNewTab
        self.close = close
    }

    var body: some View {
        Group {
            if let error = model.loadError {
                VStack {
                    EmptyState(symbol: "exclamationmark.triangle", title: "Can't open this repository", message: error)
                    Button("Choose Another…", action: close).padding(.bottom, Theme.Space.xxl)
                }
            } else {
                RepoView(model: model, openHere: openHere, openInNewTab: openInNewTab)
            }
        }
        .task {
            await model.load()
            if model.loadError == nil { Prefs.addRecent(model.mainWorktreePath ?? model.root.path) }
            #if DEBUG
            await DebugSnapshot.applySelection(model)
            #endif
        }
        .onAppear {
            OpenRepos.add(path)
            model.openWorktree = openHere
        }
        .onDisappear {
            OpenRepos.remove(path)
            model.openWorktree = nil
            model.stopWatching()
        }
    }
}

/// A background tab from the launch before it's selected: just its name in
/// the tab strip, no repository loaded, nothing watched or fetched.
private struct UnloadedTab: View {
    let path: String

    var body: some View {
        let label = LaunchFolders.tabLabel(for: path)
        Color.clear
            .navigationTitle(label.worktree.map { "\(label.name) · \($0)" } ?? label.name)
            .background(RepoTabLabelReporter(label: label))
            // Counts as open, so opening it again selects this tab.
            .onAppear { OpenRepos.add(path) }
            .onDisappear { OpenRepos.remove(path) }
    }
}

/// The window a RepoWindow is shown in, so it can close itself.
@MainActor
final class HostWindow {
    weak var window: NSWindow?
}

/// Sets up the window chrome once and makes new windows join the opener's tab group.
struct WindowAccessor: NSViewRepresentable {
    /// Window the next new window should join as a tab. Weak and one-shot: if
    /// no window appears (SwiftUI only focused an existing one), it is dropped
    /// shortly after, so a later ⌘N isn't tabbed into a stale parent.
    @MainActor private(set) static weak var pendingTabParent: NSWindow?
    @MainActor private static var pendingGeneration = 0

    /// The next new window joins `parent`'s group at `index` as a background
    /// tab: hidden until placed, then `parent` stays selected.
    private struct PendingBackground {
        weak var parent: NSWindow?
        let index: Int
        let done: (Bool) -> Void
    }

    @MainActor private static var pendingBackground: PendingBackground?

    @MainActor static func setPendingBackground(parent: NSWindow, index: Int, done: @escaping (Bool) -> Void) {
        pendingBackground?.done(false)
        pendingBackground = PendingBackground(parent: parent, index: index, done: done)
        pendingGeneration += 1
        let generation = pendingGeneration
        // SwiftUI may only focus an existing window: don't wait forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard pendingGeneration == generation, let pending = pendingBackground else { return }
            pendingBackground = nil
            pending.done(false)
        }
    }

    @MainActor static func setPendingParent(_ window: NSWindow?) {
        pendingTabParent = window
        pendingGeneration += 1
        let generation = pendingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if pendingGeneration == generation { pendingTabParent = nil }
        }
    }

    /// Remembers the window this view lives in.
    let host: HostWindow

    func makeNSView(context: Context) -> NSView { TrackingView(host: host) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingView: NSView {
        private weak var configured: NSWindow?
        private let host: HostWindow

        init(host: HostWindow) {
            self.host = host
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { host.window = window }
            guard let window, window !== configured else { return }
            configured = window
            WindowChrome.configure(window)
            if let background = WindowAccessor.pendingBackground, let parent = background.parent, parent !== window {
                WindowAccessor.pendingBackground = nil
                // Invisible until it is a tab, so no window flashes up on its own.
                window.alphaValue = 0
                DispatchQueue.main.async {
                    if let group = parent.tabGroup {
                        group.insertWindow(window, at: min(max(0, background.index), group.windows.count))
                        group.selectedWindow = parent
                    } else {
                        parent.addTabbedWindow(window, ordered: .above)
                    }
                    parent.makeKeyAndOrderFront(nil)
                    window.alphaValue = 1
                    background.done(true)
                }
                return
            }
            let parent = WindowAccessor.pendingTabParent
            WindowAccessor.pendingTabParent = nil
            if let parent, parent !== window, parent.isVisible {
                DispatchQueue.main.async {
                    parent.addTabbedWindow(window, ordered: .above)
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}
