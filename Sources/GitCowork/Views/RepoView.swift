import GitCoworkCore
import SwiftUI

/// The main window for one worktree: sidebar | center | inspector.
///
/// This body only does layout. Each column is its own view that reads just
/// the model values it needs, so typing a commit message or selecting a
/// commit doesn't re-render the sidebar or the toolbar.
struct RepoView: View {
    @Bindable var model: RepoModel
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void

    @AppStorage(Prefs.Key.sidebarVisible) private var sidebarVisible = true

    var body: some View {
        // A plain split (not NavigationSplitView): the toolbar and the tab bar
        // then span the whole window, and all three panel headers start on the
        // same line, like GitKraken.
        VStack(spacing: 0) {
            HSplitView {
                if sidebarVisible {
                    SidebarColumn(model: model, openHere: openHere, openInNewTab: openInNewTab)
                        .equatable()
                        .frame(minWidth: Layout.sidebarMin, idealWidth: Layout.sidebarIdeal, maxWidth: Layout.sidebarMax, maxHeight: .infinity)
                        // Not under the tab bar: only the panel itself is tinted.
                        .background(Theme.sidebarBackground, ignoresSafeAreaEdges: [])
                }
                CenterColumn(model: model, openHere: openHere, openInNewTab: openInNewTab)
                    .frame(minWidth: Layout.centerMin, idealWidth: Layout.centerIdeal, maxWidth: .infinity, maxHeight: .infinity)
                InspectorColumn(model: model)
                    .frame(minWidth: Layout.inspectorMin, idealWidth: Layout.inspectorIdeal, maxWidth: Layout.inspectorMax, maxHeight: .infinity)
            }
            CommandLogArea(model: model)
            Divider()
            StatusBar(model: model)
        }
        .toolbar {
            RepoToolbar(model: model, openHere: openHere, openInNewTab: openInNewTab) {
                withAnimation(.easeOut(duration: 0.15)) { sidebarVisible.toggle() }
            }
        }
        .searchable(text: $model.filterText, placement: .toolbar, prompt: "Filter commits")
        .navigationTitle(title)
        .modifier(HideToolbarTitle())
        .background(RepoTabLabelReporter(label: tabLabel))
        .modifier(RepoDialogs(model: model, openInNewTab: openInNewTab))
        .focusedSceneValue(\.repoModel, model)
    }

    /// Column widths, close to GitKraken's defaults.
    private enum Layout {
        static let sidebarMin: CGFloat = 220
        static let sidebarIdeal: CGFloat = 300
        static let sidebarMax: CGFloat = 440
        static let centerMin: CGFloat = 480
        static let centerIdeal: CGFloat = 760
        static let inspectorMin: CGFloat = 320
        static let inspectorIdeal: CGFloat = 440
        static let inspectorMax: CGFloat = 680
    }

    /// Window title: "repo", or "repo · folder" for a linked worktree.
    private var title: String {
        tabLabel.worktree.map { "\(model.name) · \($0)" } ?? model.name
    }

    /// The tab shows the same, with the folder in a quieter style.
    private var tabLabel: RepoTabLabel {
        let isMain = model.mainWorktreePath == nil || model.mainWorktreePath == model.root.path
        return RepoTabLabel(name: model.name, worktree: isMain ? nil : model.root.lastPathComponent)
    }
}

/// The sidebar, compared by model identity only: its closures never change
/// meaning for a window, so parent re-renders don't rebuild the sidebar list.
private struct SidebarColumn: View, Equatable {
    let model: RepoModel
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void

    nonisolated static func == (a: SidebarColumn, b: SidebarColumn) -> Bool { a.model === b.model }

    var body: some View {
        SidebarView(model: model, openHere: openHere, openInNewTab: openInNewTab)
    }
}

/// History graph, task board or review list. An open diff covers whichever
/// is showing; Esc (which clears `openDiff`) returns to it.
private struct CenterColumn: View {
    let model: RepoModel
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void

    var body: some View {
        let diff = model.openDiff
        let mode = model.centerMode
        ZStack(alignment: .bottom) {
            // Kept alive under a diff so the graph keeps its scroll position.
            if mode == .history {
                HistoryCenter(model: model, openHere: openHere, openInNewTab: openInNewTab)
                    .opacity(diff == nil ? 1 : 0)
                    .allowsHitTesting(diff == nil)
                if diff == nil, model.isLoaded, model.headSHA == nil, model.commits.isEmpty {
                    EmptyRepoState(model: model)
                }
            } else if diff == nil {
                switch mode {
                case .board: BoardView(model: model)
                case .reviews: ReviewsView(model: model)
                case .history: EmptyView()
                }
            }
            if let diff {
                DiffPane(model: model, target: diff)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            UndoHint(model: model)
                .padding(.bottom, Theme.Space.l)
        }
    }
}

/// "Committed · Undo" for a few seconds after an action Edit > Undo can take
/// back, so it's clear that it can (and how). Goes away by itself.
private struct UndoHint: View {
    let model: RepoModel
    @State private var shown: UndoRecord?
    @State private var hide: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let record = shown, model.lastUndo == record {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Status.success)
                    Text(verbatim: record.doneText).font(Theme.Font.body.weight(.medium))
                    Button("Undo") {
                        shown = nil
                        Task { await model.undoLastAction() }
                    }
                    .buttonStyle(ActionButtonStyle.secondary())
                    .disabled(model.undoTitle == nil || model.busy != nil)
                    Text(verbatim: "⌘Z").font(Theme.Font.small).foregroundStyle(.tertiary)
                    Button {
                        shown = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Hide")
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: shown)
        .onChange(of: model.lastUndo) { _, record in
            hide?.cancel()
            shown = record
            guard record != nil else { return }
            hide = Task {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { shown = nil }
            }
        }
    }
}

extension UndoRecord {
    /// What just happened, for the undo hint.
    var doneText: String {
        switch action {
        case .commit: L("Committed")
        case .amend: L("Amended the last commit")
        case .reset: L("Reset the branch")
        case .checkout: L("Switched")
        case .deleteBranch(let name, _, _): String(localized: "Deleted \(name)")
        case .discard: L("Discarded the changes")
        }
    }
}

/// The commit graph. Reads the values that change while typing or selecting,
/// so only this view (and the table it wraps) updates for them.
private struct HistoryCenter: View {
    let model: RepoModel
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void

    var body: some View {
        HistoryTable(
            model: model,
            version: model.historyVersion,
            filter: model.filterText,
            wipCount: model.status.changeCount,
            selection: model.selection,
            revealToken: model.revealToken,
            worktreeInfoVersion: model.worktreeInfoVersion,
            draftSummary: model.draftSummary,
            openHere: openHere,
            openInNewTab: openInNewTab)
    }
}

/// Right panel: changes / commit details on History, the selected task or
/// review on Board and Reviews.
private struct InspectorColumn: View {
    let model: RepoModel

    var body: some View {
        switch model.centerMode {
        case .history:
            switch model.selection {
            case .workingCopy:
                ChangesPanel(model: model)
            case .commit(let sha):
                CommitPanel(model: model, sha: sha)
            case nil:
                EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "Select a commit")
            }
        case .board, .reviews:
            switch model.coworkSelection {
            case .task(let id):
                TaskPanel(model: model, taskID: id).id(id)
            case .review(let id):
                ReviewPanel(model: model, reviewID: id).id(id)
            case nil:
                if model.centerMode == .board {
                    EmptyState(symbol: "rectangle.split.3x1", title: "No task selected",
                               message: "Pick a card to see its details and comments, or press ⇧⌘T for a new task.")
                } else {
                    EmptyState(symbol: "checkmark.bubble", title: "No review selected",
                               message: "Pick a review request to see its changes and comments.")
                }
            }
        }
    }
}

/// Command log drawer above the status bar (⌘J).
private struct CommandLogArea: View {
    let model: RepoModel
    private static let height: CGFloat = 200

    var body: some View {
        if model.showCommandLog {
            Divider()
            CommandLogView(root: model.root)
                .frame(height: Self.height)
        }
    }
}

/// Alerts, confirmations and sheets driven by the model.
private struct RepoDialogs: ViewModifier {
    @Bindable var model: RepoModel
    let openInNewTab: (String) -> Void

    func body(content: Content) -> some View {
        content
            .alert(Text(ui: model.alert?.title ?? ""), isPresented: isPresented(\.alert), presenting: model.alert) { _ in
                Button("OK") {}
                Button("Show Command Log") { model.showCommandLog = true }
            } message: { a in
                Text(ui: a.message)
            }
            .alert(Text(ui: model.confirmation?.title ?? ""), isPresented: isPresented(\.confirmation), presenting: model.confirmation) { c in
                Button(L(c.confirmTitle), role: c.destructive ? .destructive : nil) { Task { await c.action() } }
                if let title = c.alternativeTitle, let alternative = c.alternative {
                    Button(title, role: c.destructive ? .destructive : nil) { Task { await alternative() } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { c in
                Text(ui: c.message)
            }
            .sheet(item: $model.problem) { p in
                ProblemSheet(problem: p) { model.showCommandLog = true }
            }
            .sheet(item: $model.sheet) { kind in
                RepoSheet(model: model, kind: kind, openInNewTab: openInNewTab)
            }
    }

    private func isPresented<T>(_ key: ReferenceWritableKeyPath<RepoModel, T?>) -> Binding<Bool> {
        Binding(get: { model[keyPath: key] != nil }, set: { if !$0 { model[keyPath: key] = nil } })
    }
}

/// A repository without any commit (a fresh `git init`, or a clone of an
/// empty one): one button makes the first commit, with a README if needed.
private struct EmptyRepoState: View {
    let model: RepoModel

    var body: some View {
        EmptyState(symbol: "sparkles", title: "No commits yet",
                   message: "Make the first commit to start the history. If there's no README.md yet, git-cowork adds one with the repository's name.",
                   messageWidth: 360) {
            Button("Create Initial Commit") { Task { await model.makeInitialCommit() } }
                .buttonStyle(ActionButtonStyle.primary())
                .disabled(model.busy != nil)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
