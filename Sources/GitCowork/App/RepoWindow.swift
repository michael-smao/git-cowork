import AppKit
import GitCoworkCore
import SwiftUI

/// One window (tab). Shows the welcome screen until a repo is chosen. A tab
/// showing a workspace has the workspace's tree on the left; picking a
/// repository there shows it in the same tab.
struct RepoWindow: View {
    @Binding var target: TabTarget?
    @State private var showClone = false
    /// Scan Folder: the folder picked, while its sheet is up.
    @State private var scanFolder: String?
    @State private var dropTargeted = false
    @State private var host = HostWindow()
    /// The repositories this window has shown, so it can retire them itself.
    @State private var shown = ShownRepos()
    /// A background tab from the launch: loads its repository once selected.
    @State private var waitsUntilSelected: Bool
    @AppStorage(Prefs.Key.workspaceVisible) private var workspaceVisible = true
    @AppStorage(Prefs.Key.workspaceWidth) private var workspaceWidth = Double(Layout.workspaceIdeal)
    @Environment(\.openWindow) private var openWindow

    private enum Layout {
        static let workspaceMin: CGFloat = 200
        static let workspaceIdeal: CGFloat = 260
        static let workspaceMax: CGFloat = 420
    }

    init(target: Binding<TabTarget?>) {
        _target = target
        _waitsUntilSelected = State(initialValue: target.wrappedValue.map(LaunchFolders.opensInBackground) ?? false)
    }

    private var path: String? { target?.path }
    private var workspace: Workspace? { WorkspaceStore.shared.workspace(target?.workspace) }

    var body: some View {
        Group {
            if let target, waitsUntilSelected {
                UnloadedTab(target: target)
            } else if let workspace {
                workspaceSplit(workspace)
            } else if let path {
                repo(path)
            } else {
                WelcomeView(open: { open($0) }, clone: { showClone = true }, scan: chooseScanFolder,
                            openWorkspace: openWorkspace)
            }
        }
        .environment(\.windowActions, actions)
        .frame(minWidth: 900, minHeight: 500)
        .background(WindowAccessor(host: host))
        // Remembered for the next launch (OpenSession).
        .onAppear { OpenSession.track(host, target: target) }
        .onChange(of: target) { _, new in OpenSession.track(host, target: new) }
        .onDisappear { OpenSession.untrack(host) }
        // SwiftUI doesn't always end the view when its window closes (a
        // workspace tab's split view stayed), so the closed tab would come
        // back at the next launch. The window closing is certain.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let window = host.window, note.object as? NSWindow === window else { return }
            OpenSession.untrack(host)
            shown.retire(except: nil)
        }
        // The same for the repository this tab showed before: it stops being
        // watched and fetched, and no longer counts as open in a tab.
        .onChange(of: target?.path) { _, new in shown.retire(except: new) }
        // Only an empty (welcome) window takes `open -a git-cowork <dir>`;
        // windows showing a repo decline, so SwiftUI opens a new tab instead.
        .handlesExternalEvents(preferring: target == nil ? ["*"] : [], allowing: target == nil ? ["*"] : [])
        .onAppear {
            if target == nil { openLaunchFolders() }
            if LaunchFolders.pendingClone {
                LaunchFolders.pendingClone = false
                showClone = true
            }
            if let folder = LaunchFolders.pendingScan {
                LaunchFolders.pendingScan = nil
                startScan(folder)
            }
            if let id = LaunchFolders.pendingWorkspace {
                LaunchFolders.pendingWorkspace = nil
                openWorkspace(id)
            }
        }
        // The first window can appear before the command line is read.
        .onReceive(NotificationCenter.default.publisher(for: .launchFoldersPending)) { _ in
            if target == nil { openLaunchFolders() }
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
        .sheet(isPresented: Binding(get: { scanFolder != nil }, set: { if !$0 { scanFolder = nil } })) {
            if let scanFolder {
                ScanFolderSheet(folder: scanFolder) { openWorkspace($0) }
            }
        }
        .focusedSceneValue(\.windowActions, actions)
    }

    private func repo(_ path: String) -> some View {
        RepoContainer(path: path, host: host, shown: shown, openHere: openHere, openInNewTab: openTab, close: { setPath(nil) })
            .id(path)
    }

    /// Tree | repository. The tree stays while the repository beside it changes.
    /// Not an HSplitView: that hands out the width again whenever the
    /// repository or the window size changes. The tree keeps the width it is
    /// dragged to, in every tab.
    private func workspaceSplit(_ workspace: Workspace) -> some View {
        HStack(spacing: 0) {
            if workspaceVisible {
                WorkspaceColumn(workspace: workspace, current: path, select: showInWorkspace, openInNewTab: openTab)
                    .frame(width: CGFloat(clampedWorkspaceWidth))
                    .frame(maxHeight: .infinity)
                    // Not under the tab bar: only the panel itself is tinted.
                    .background(Theme.sidebarBackground, ignoresSafeAreaEdges: [])
                ResizeDivider(width: $workspaceWidth, range: Double(Layout.workspaceMin)...Double(Layout.workspaceMax))
            }
            Group {
                if let path {
                    repo(path)
                } else {
                    EmptyState(symbol: WorkspaceStyle.symbol, title: "Choose a repository",
                               message: "Pick one in the workspace on the left.") {
                        if !workspaceVisible {
                            Button("Show Workspace") { workspaceVisible = true }
                        }
                    }
                    .navigationTitle(workspace.name)
                    .background(RepoTabLabelReporter(label: RepoTabLabel(name: "", worktree: nil, workspace: workspace.name)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.toggleWorkspace) {
            withAnimation(.easeOut(duration: 0.15)) { workspaceVisible.toggle() }
        }
        .environment(\.workspaceName, workspace.name)
    }

    private var clampedWorkspaceWidth: Double {
        min(max(workspaceWidth, Double(Layout.workspaceMin)), Double(Layout.workspaceMax))
    }

    private var actions: WindowActions {
        WindowActions(open: { open($0) }, showClone: { showClone = true }, scanFolder: chooseScanFolder,
                      openWorkspace: openWorkspace, workspace: workspace?.id)
    }

    /// The tab's repository; a workspace tab keeps its workspace without one.
    private func setPath(_ new: String?) {
        if target?.workspace != nil {
            target?.path = new
        } else {
            target = new.map { TabTarget(path: $0) }
        }
    }

    /// Picked in the workspace's tree: shown here, and opened first next time.
    private func showInWorkspace(_ p: String) {
        setPath(p)
        if let id = workspace?.id {
            WorkspaceStore.shared.update(id) { ws in
                if ws.repos.contains(p) { ws.lastRepo = p }
            }
        }
    }

    private func chooseScanFolder() {
        if let folder = FolderPicker.choose(message: L("Choose a folder to look for repositories in")) { startScan(folder) }
    }

    /// A folder that already has a workspace opens that one instead of making a second.
    private func startScan(_ folder: String) {
        if let existing = WorkspaceStore.shared.workspace(scanRoot: folder) {
            openWorkspace(existing.id)
        } else {
            scanFolder = folder
        }
    }

    /// Opens a workspace here if this window is empty, else in a new tab. A
    /// tab already showing it comes to the front instead.
    private func openWorkspace(_ id: String) {
        guard let ws = WorkspaceStore.shared.workspace(id) else { return }
        if target?.workspace == id { return }
        if let window = OpenSession.window(showingWorkspace: id) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let start = TabTarget(path: ws.startRepo.flatMap { WorkspaceDisk.exists($0) ? $0 : nil }, workspace: id)
        if target == nil { target = start } else { openTab(start) }
    }

    /// At launch (last session, command line): the front repository opens
    /// here right away; the others join as background tabs in their order,
    /// one after another, without coming to the front or loading yet.
    private func openLaunchFolders() {
        let tabs = LaunchFolders.takeAll()
        guard !tabs.isEmpty else { return }
        let wanted = LaunchFolders.front.flatMap(tabs.firstIndex(of:)) ?? 0
        Task {
            var resolved: [TabTarget?] = []
            for tab in tabs { resolved.append(await LaunchFolders.resolve(tab)) }
            // The front one, or the first that is still a repository or workspace.
            let order = [wanted] + resolved.indices.filter { $0 != wanted }
            guard let frontIndex = order.first(where: { resolved[$0] != nil }), let front = resolved[frontIndex] else {
                LaunchFolders.finishRestore()
                return
            }
            if target == nil { target = front } else { openTab(front) }
            // Where each tab goes: before the ones that come later in the saved order.
            var placed: [Int] = [frontIndex]
            for index in resolved.indices where index != frontIndex {
                guard let tab = resolved[index], !LaunchFolders.isOpen(tab) else { continue }
                if await openBackgroundTab(tab, at: placed.filter { $0 < index }.count) { placed.append(index) }
            }
            LaunchFolders.finishRestore()
        }
    }

    /// Opens `tab` at `index` of this window's group, behind this one.
    /// Returns once it is there (false if no window came within 2 seconds).
    private func openBackgroundTab(_ tab: TabTarget, at index: Int) async -> Bool {
        guard let parent = host.window else { return false }
        return await withCheckedContinuation { continuation in
            WindowAccessor.setPendingBackground(parent: parent, index: index) { continuation.resume(returning: $0) }
            LaunchFolders.markBackground(tab)
            openWindow(id: "repo", value: tab)
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
            if target == nil { target = TabTarget(path: resolved) } else { openTab(resolved) }
        }
    }

    /// Switches this window to another worktree, unless that worktree is
    /// already open in another tab: then that tab comes to the front.
    /// If the folder this window shows is gone or being removed, the window
    /// closes once the other tab is in front, rather than staying on a
    /// deleted folder. A workspace tab always switches itself, like a click
    /// in its tree.
    private func openHere(_ p: String) {
        // Asks OpenSession, which follows what each tab shows right now; the
        // OpenRepos counts lagged one switch behind in workspace tabs.
        guard target?.workspace == nil, let other = OpenSession.window(showing: p, except: host.window) else {
            setPath(p)
            return
        }
        other.tabGroup?.selectedWindow = other
        other.makeKeyAndOrderFront(nil)
        if let current = path,
           WorktreeRemovals.shared.contains(current) || !FileManager.default.fileExists(atPath: current) {
            let window = host.window
            DispatchQueue.main.async { window?.close() }
        }
    }

    /// New tab next to this window, showing just the repository.
    private func openTab(_ p: String) { openTab(TabTarget(path: p)) }

    /// SwiftUI brings an existing window to the front when one already shows
    /// `tab`. For just a repository that would miss a workspace tab showing
    /// it (another value), so look for that first, as before workspaces.
    private func openTab(_ tab: TabTarget) {
        if tab.workspace == nil, let p = tab.path, let window = OpenSession.window(showing: p, except: host.window) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        WindowAccessor.setPendingParent(NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.orderedWindows.first { $0.isVisible && $0.tabbingIdentifier == WindowChrome.tabbingIdentifier })
        openWindow(id: "repo", value: tab)
    }
}

/// Shows or hides the workspace tree of this tab; nil in tabs without one.
private struct ToggleWorkspaceKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

/// The name of the workspace this tab shows, for the tab label.
private struct WorkspaceNameKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var toggleWorkspace: (() -> Void)? {
        get { self[ToggleWorkspaceKey.self] }
        set { self[ToggleWorkspaceKey.self] = newValue }
    }

    var workspaceName: String? {
        get { self[WorkspaceNameKey.self] }
        set { self[WorkspaceNameKey.self] = newValue }
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

/// The models of the repositories shown in a tab (RepoPresence), so the
/// workspace tree shows their changes and commits to push as the models'
/// own refreshes, file watching and fetching update them.
@MainActor @Observable
final class LiveRepos {
    static let shared = LiveRepos()

    private(set) var models: [RepoModel] = []

    private init() {}

    func add(_ model: RepoModel) {
        if !models.contains(where: { $0 === model }) { models.append(model) }
    }

    func remove(_ model: RepoModel) {
        models.removeAll { $0 === model }
    }

    /// What a loaded model knows about the worktree at `path`: the model
    /// showing it first, else the model of another worktree of its repository.
    func info(_ path: String) -> WorktreeInfo? {
        let loaded = models.filter(\.isLoaded)
        if let own = loaded.first(where: { $0.root.path == path }), let info = own.worktreeInfo[path] { return info }
        return loaded.lazy.compactMap { $0.worktreeInfo[path] }.first
    }
}

/// Creates the model for a worktree and keeps it for the window's lifetime.
///
/// A tab that stays behind another one for a while goes to sleep: its views
/// are taken down (they are most of a tab's memory), the model stays. So
/// fetching, watching and notifications go on, and nothing typed or selected
/// is lost; selecting the tab builds the views again from the loaded model.
private struct RepoContainer: View {
    @State private var model: RepoModel
    @State private var presence: RepoPresence
    @State private var asleep = false
    @State private var idle: Task<Void, Never>?
    let shown: ShownRepos
    let host: HostWindow
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void
    let close: () -> Void

    init(path: String, host: HostWindow, shown: ShownRepos, openHere: @escaping (String) -> Void,
         openInNewTab: @escaping (String) -> Void, close: @escaping () -> Void) {
        let model = RepoModel(root: URL(fileURLWithPath: path))
        _model = State(initialValue: model)
        _presence = State(initialValue: RepoPresence(path: path, model: model))
        self.shown = shown
        self.host = host
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
            } else if asleep {
                SleepingTab(model: model)
            } else {
                RepoView(model: model, openHere: openHere, openInNewTab: openInNewTab)
            }
        }
        // Bumped whenever a tab is selected, added or closed.
        .onChange(of: RepoTabs.shared.version) { updateSleep() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Right away when selected, before the tab strip catches up.
            if asleep || !model.isShowing, let window = host.window, note.object as? NSWindow === window { updateSleep() }
        }
        .task {
            await model.load()
            if model.loadError == nil { Prefs.addRecent(model.mainWorktreePath ?? model.root.path) }
            #if DEBUG
            await DebugSnapshot.applySelection(model)
            #endif
        }
        .onAppear {
            shown.add(presence)
            presence.begin(openHere: openHere)
        }
        // The window retires it too (ShownRepos): SwiftUI doesn't always get here.
        .onDisappear {
            presence.end()
            idle?.cancel()
        }
    }

    /// Wakes the tab when it is in front; otherwise starts the wait to sleep.
    private func updateSleep() {
        guard let window = host.window, TabSleep.isBehindAnotherTab(window) else {
            idle?.cancel()
            idle = nil
            if asleep { asleep = false }
            model.setShowing(true)
            return
        }
        model.setShowing(false)
        guard idle == nil, !asleep else { return }
        idle = Task {
            var wait = TabSleep.after
            while true {
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
                if canSleep { break }
                // Busy or showing a dialog: look again in a while.
                wait = TabSleep.retry
            }
            idle = nil
            asleep = true
            TabSleep.releaseFreedMemory()
        }
    }

    /// Not in the middle of something only the views hold.
    private var canSleep: Bool {
        guard let window = host.window, TabSleep.isBehindAnotherTab(window) else { return false }
        return model.isLoaded && model.busy == nil && model.sheet == nil && model.confirmation == nil
            && model.alert == nil && model.problem == nil && window.attachedSheet == nil
    }
}

/// One repository shown in a window: counts as open in a tab, and its model
/// watches and fetches, until `end`. Ends once, from whichever side gets there first.
@MainActor
final class RepoPresence {
    let path: String
    private let model: RepoModel
    private var active = false

    init(path: String, model: RepoModel) {
        self.path = path
        self.model = model
    }

    func begin(openHere: @escaping (String) -> Void) {
        guard !active else { return }
        active = true
        OpenRepos.add(path)
        LiveRepos.shared.add(model)
        model.openWorktree = openHere
    }

    func end() {
        guard active else { return }
        active = false
        OpenRepos.remove(path)
        LiveRepos.shared.remove(model)
        model.openWorktree = nil
        model.stopWatching()
    }
}

/// The repositories a window has shown. When it shows another one or
/// closes, it ends the ones it no longer shows.
@MainActor
final class ShownRepos {
    private var all: [RepoPresence] = []

    func add(_ presence: RepoPresence) {
        if !all.contains(where: { $0 === presence }) { all.append(presence) }
    }

    /// Ends all but the one showing `path`.
    func retire(except path: String?) {
        for presence in all where presence.path != path { presence.end() }
        all.removeAll { $0.path != path }
    }
}

/// When a background tab's views are taken down.
@MainActor
enum TabSleep {
    /// How long a tab stays behind another one before it sleeps.
    static let after: TimeInterval = {
        #if DEBUG
        // GITCOWORK_TAB_SLEEP=<seconds>: sleep sooner, for measuring.
        if let s = ProcessInfo.processInfo.environment["GITCOWORK_TAB_SLEEP"].flatMap(Double.init) { return s }
        #endif
        return 5 * 60
    }()
    static var retry: TimeInterval { min(after, 60) }

    private static var release: Task<Void, Never>?

    /// The allocator keeps the pages of freed views for reuse, so the app's
    /// memory wouldn't go down. Once the views are gone (a moment after the
    /// last tab went to sleep), hands the empty pages back to the system.
    static func releaseFreedMemory() {
        release?.cancel()
        release = Task {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// In a tab group with another tab in front (not just covered or minimized).
    static func isBehindAnotherTab(_ window: NSWindow) -> Bool {
        guard let group = window.tabGroup, group.windows.count > 1, let selected = group.selectedWindow else { return false }
        return selected !== window
    }
}

/// A sleeping tab: its name in the tab strip, no views. The model is alive.
private struct SleepingTab: View {
    let model: RepoModel
    @Environment(\.workspaceName) private var workspaceName

    var body: some View {
        // In a workspace tab, its name stays in the label while asleep.
        let label = model.tabLabel.inWorkspace(workspaceName)
        Color.clear
            .navigationTitle(label.title)
            .background(RepoTabLabelReporter(label: label))
    }
}

/// A background tab from the launch before it's selected: just its name in
/// the tab strip, no repository loaded, nothing watched or fetched.
private struct UnloadedTab: View {
    let target: TabTarget

    var body: some View {
        let label = LaunchFolders.tabLabel(for: target)
        Color.clear
            .navigationTitle(label.title)
            .background(RepoTabLabelReporter(label: label))
            // Counts as open, so opening it again selects this tab.
            .onAppear { if let path = target.path { OpenRepos.add(path) } }
            .onDisappear { if let path = target.path { OpenRepos.remove(path) } }
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
