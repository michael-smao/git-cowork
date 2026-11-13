import AppKit
import GitCoworkCore
import SwiftUI

/// Menu bar commands with keyboard shortcuts. They act on the focused window.
struct AppCommands: Commands {
    @FocusedValue(\.repoModel) private var model
    @FocusedValue(\.windowActions) private var window
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.Key.workspaceVisible) private var workspaceVisible = true
    private var workspaces: WorkspaceStore { WorkspaceStore.shared }

    /// A repo window is focused and no git command is running, so a new one
    /// can't overlap it (same rule as the toolbar buttons).
    private var idle: Bool { model != nil && model?.busy == nil }

    private var textFocus: TextFocus { TextFocus.shared }

    /// "Undo Commit" etc. when the focused repo's last git action can be taken back.
    private var gitUndoTitle: String? { idle ? model?.undoTitle : nil }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.checkFromMenu() }
        }

        CommandGroup(after: .newItem) {
            Button("New Tab") { WindowChrome.newTab() }
                .keyboardShortcut("t")
            Button("Open Repository…") {
                guard let path = RepoPicker.choose() else { return }
                if let window { window.open(path) } else { openInNewWindow(path) }
            }
            .keyboardShortcut("o")
            Button("Clone Repository…") {
                if let window {
                    window.showClone()
                } else {
                    // No window open: make an empty one, which shows the clone sheet.
                    LaunchFolders.pendingClone = true
                    LaunchFolders.newWindow()
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Scan Folder…") {
                if let window {
                    window.scanFolder()
                } else if let folder = FolderPicker.choose(message: L("Choose a folder to look for repositories in")) {
                    LaunchFolders.pendingScan = folder
                    LaunchFolders.newWindow()
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            Menu("Open Workspace") {
                ForEach(workspaces.sorted) { ws in
                    Button(ws.name) {
                        if let window {
                            window.openWorkspace(ws.id)
                        } else {
                            LaunchFolders.pendingWorkspace = ws.id
                            LaunchFolders.newWindow()
                        }
                    }
                }
            }
            .disabled(workspaces.all.isEmpty)
        }

        // While text is being edited, Undo / Redo act on the text as usual;
        // otherwise Undo takes back the last git action.
        CommandGroup(replacing: .undoRedo) {
            Button(textFocus.isEditing ? L("Undo") : gitUndoTitle ?? L("Undo")) {
                if TextFocus.editingTextView() != nil {
                    TextFocus.undoText()
                } else if gitUndoTitle != nil {
                    run { await $0.undoLastAction() }
                }
            }
            .keyboardShortcut("z")
            .disabled(!textFocus.isEditing && gitUndoTitle == nil)
            Button("Redo") { TextFocus.redoText() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!textFocus.isEditing)
        }

        // Ahead of Edit > Find so ⌘F filters commits in a repo window.
        CommandGroup(before: .textEditing) {
            Button(searchCommandTitle) { WindowChrome.focusFilter() }
                .keyboardShortcut("f")
                .disabled(model == nil)
        }

        CommandGroup(before: .sidebar) {
            Button(workspaceVisible ? "Hide Workspace" : "Show Workspace") {
                withAnimation(.easeOut(duration: 0.15)) { workspaceVisible.toggle() }
            }
            .keyboardShortcut("p", modifiers: [.command, .control])
            .disabled(window?.workspace == nil)
            Divider()
            ForEach(Array(CenterMode.allCases.enumerated()), id: \.element) { i, mode in
                Button(mode.title) {
                    model?.openDiff = nil
                    model?.centerMode = mode
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                .disabled(model == nil)
            }
            Divider()
        }

        CommandMenu("Repository") {
            Button("Refresh") { run { await $0.refresh() } }
                .keyboardShortcut("r")
                .disabled(model == nil)
            Divider()
            Button("Fetch All") { run { await $0.fetch() } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!idle)
            Button("Pull") { run { await $0.pull() } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!idle)
            Button("Push") { run { await $0.push() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!idle)
            Divider()
            Button("New Branch…") {
                guard let m = model else { return }
                m.sheet = .newBranch(from: m.currentBranch ?? "HEAD", label: m.currentBranch ?? "HEAD")
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!idle)
            Button("Add Worktree…") { model?.sheet = .addWorktree(base: model?.currentBranch) }
                .disabled(!idle)
            Button("Stash Changes…") { model?.sheet = .stash }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!idle || model?.status.isClean != false)
            Button("Pop Stash") { run { await $0.popStash() } }
                .keyboardShortcut("s", modifiers: [.command, .shift, .option])
                .disabled(!idle || model?.stashes.isEmpty != false)
            Divider()
            Button("New Task…") {
                guard let m = model else { return }
                m.centerMode = .board
                m.openDiff = nil
                m.sheet = .newTask(status: .todo)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(model == nil)
            Button(model?.currentBranch.map { String(localized: "Request Review of \($0)…") } ?? L("Request Review…")) {
                guard let m = model, let branch = m.currentBranch else { return }
                m.sheet = .requestReview(branch: branch)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model?.currentBranch == nil)
            Button("Edit Team…") { model?.sheet = .team }
                .disabled(model == nil)
            Button("Sync Tasks Now") { run { await $0.syncCowork() } }
                .disabled(model == nil || model?.cowork.syncing == true)
            Divider()
            Button("Show Uncommitted Changes") {
                model?.centerMode = .history
                model?.selection = .workingCopy
                model?.openDiff = nil
            }
            .keyboardShortcut("0")
            .disabled(model == nil)
            Button("Open in Terminal") { if let m = model { External.openTerminal(m.root.path) } }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Open in Editor") { if let m = model { External.openEditor(m.root.path) } }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Reveal in Finder") { if let m = model { External.reveal(m.root.path) } }
                .disabled(model == nil)
            Divider()
            Button(model?.showCommandLog == true ? "Hide Command Log" : "Show Command Log") {
                model?.showCommandLog.toggle()
            }
            .keyboardShortcut("j")
            .disabled(model == nil)
        }
    }

    /// ⌘F goes to the toolbar search, which searches what the center shows.
    private var searchCommandTitle: String {
        switch model?.centerMode {
        case .board: L("Search Tasks")
        case .reviews: L("Search Reviews")
        default: L("Filter Commits")
        }
    }

    private func run(_ action: @escaping (RepoModel) async -> Void) {
        guard let model else { return }
        Task { await action(model) }
    }

    /// File > Open with no window open: resolve to the worktree's top level
    /// first, like opening from a window does.
    private func openInNewWindow(_ path: String) {
        Task { @MainActor in
            if let resolved = await RepoLocator.resolve(path) {
                openWindow(id: "repo", value: TabTarget(path: resolved))
            } else {
                let alert = NSAlert()
                alert.messageText = L("Not a git repository")
                alert.informativeText = path
                alert.runModal()
            }
        }
    }
}
