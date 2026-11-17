import GitCoworkCore
import SwiftUI

/// Right panel for another worktree's "// WIP" row: its uncommitted files
/// (click one for the diff) and buttons to switch to it. Read-only: staging
/// and committing happen in the worktree's own tab.
struct WorktreePanel: View {
    let model: RepoModel
    let path: String
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void

    @State private var collapsedFolders: Set<String> = []
    @State private var collapsedSections: Set<String> = []
    @AppStorage(FileViewMode.storageKey) private var mode: FileViewMode = .path
    @AppStorage(FileSortMode.storageKey) private var sort: FileSortMode = .path

    private var worktree: Worktree? { model.worktrees.first { $0.path == path } }
    private var status: WorkingStatus? { model.worktreeChanges[path] }

    /// Reloads whenever this repository refreshes or a worktree's counts change.
    private var reloadKey: String { "\(path)#\(model.refreshCount)#\(model.worktreeInfoVersion)" }

    var body: some View {
        VStack(spacing: 0) {
            PanelBar(spacing: Theme.Space.s) {
                Text("Worktree").font(Theme.Font.title)
                Text(verbatim: worktree?.branch ?? worktree?.displayName ?? (path as NSString).lastPathComponent)
                    .font(Theme.Font.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Spacer(minLength: Theme.Space.s)
                if let status, !status.isClean { FileViewControls() }
            }
            if !model.status.isClean {
                WorkingCopyBanner(count: model.status.changeCount) {
                    model.selection = .workingCopy
                    model.openDiff = nil
                }
            }
            header
            Divider()
            if let status {
                if status.isClean {
                    EmptyState(symbol: "checkmark.circle", title: "No uncommitted changes",
                               message: "Everything in this worktree is committed.")
                } else {
                    fileList(status)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: reloadKey) { await model.loadWorktreeChanges(path) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionGap) {
            Text("Changes in another worktree. Open it to stage and commit them.")
                .font(Theme.Font.small)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: path)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .help(path)
            ViewThatFits(in: .horizontal) {
                buttons(newTab: "Open Worktree in New Tab", here: "Open Here")
                buttons(newTab: "Open in New Tab", here: "Open Here")
                buttons(newTab: "New Tab", here: nil)
            }
        }
        .padding(Theme.Metrics.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buttons(newTab: String, here: String?) -> some View {
        HStack(spacing: Theme.Space.m) {
            Button { openInNewTab(path) } label: {
                Label(LocalizedStringKey(newTab), systemImage: "plus.square.on.square")
            }
            .buttonStyle(ActionButtonStyle.primary())
            .help("Switch to this worktree in a tab of its own (double-click the row)")
            if let here {
                Button(LocalizedStringKey(here)) { openHere(path) }
                    .buttonStyle(ActionButtonStyle.secondary())
                    .help("Show this worktree in this tab instead")
            }
            Spacer(minLength: 0)
            Menu {
                Button("Open in Terminal") { External.openTerminal(path) }
                Button("Open in Editor") { External.openEditor(path) }
                Button("Reveal in Finder") { External.reveal(path) }
                Divider()
                Button("Copy Path") { External.copy(path) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: Files

    private func fileList(_ st: WorkingStatus) -> some View {
        let unstaged = st.unstaged + st.untracked
        let all = st.conflicted + unstaged + st.staged
        return List(selection: selectedFile(all)) {
            if !st.conflicted.isEmpty { section("wt-conflicts", title: "Conflicted files", files: st.conflicted) }
            if !unstaged.isEmpty { section("wt-unstaged", title: "Unstaged files", files: unstaged) }
            if !st.staged.isEmpty { section("wt-staged", title: "Staged files", files: st.staged) }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, Theme.Metrics.rowHeight)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let f = all.first(where: { $0.id == id }) {
                Button("Show Diff") { model.openDiff = .worktree(path, f) }
                Button("Open in Editor") { External.openEditor((path as NSString).appendingPathComponent(f.path)) }
                Divider()
                Button("Copy Path") { External.copy(f.path) }
            }
        }
    }

    private func section(_ key: String, title: String, files: [FileChange]) -> some View {
        let isCollapsed = Binding(
            get: { collapsedSections.contains(key) },
            set: { if $0 { collapsedSections.insert(key) } else { collapsedSections.remove(key) } })
        return Section {
            if !isCollapsed.wrappedValue {
                let items = FileTree.items(files, mode: mode, sort: sort, collapsed: collapsedFolders, scope: key)
                ForEach(items) { item in
                    switch item {
                    case .folder(let f):
                        FolderRow(folder: f) { FileTree.toggle(f.id, in: &collapsedFolders) }
                            .selectionDisabled()
                            .listRowSeparator(.hidden)
                    case .file(let c, let depth):
                        FileRow(change: c, depth: depth, showDirectory: mode == .path)
                            .tag(c.id)
                            .listRowSeparator(.hidden)
                    }
                }
            }
        } header: {
            SectionHeader(title: title, count: files.count, collapsed: isCollapsed) { EmptyView() }
                .padding(.vertical, Theme.Space.s)
        }
    }

    private func selectedFile(_ all: [FileChange]) -> Binding<String?> {
        Binding(
            get: {
                if case .worktree(let p, let f) = model.openDiff, p == path { return f.id }
                return nil
            },
            set: { id in
                guard let id, let f = all.first(where: { $0.id == id }) else { return }
                model.openDiff = .worktree(path, f)
            })
    }
}
