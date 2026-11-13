import AppKit
import GitCoworkCore
import SwiftUI

/// Left column of a workspace tab: the workspace's repositories as a tree
/// (folders › repositories › linked worktrees). Clicking a repository or
/// worktree shows it in this tab; the column stays while it loads.
struct WorkspaceColumn: View {
    let workspace: Workspace
    /// The folder this tab shows.
    let current: String?
    let select: (String) -> Void
    let openInNewTab: (String) -> Void

    @State private var worktrees: [String: [String]] = [:]
    @State private var missing: Set<String> = []
    /// Nodes whose open/closed state differs from the default (folders open, repositories closed).
    @State private var toggled: Set<String> = []
    @State private var selection: String?
    @State private var renaming = false

    var body: some View {
        let tree = WorkspaceTree.build(repos: workspace.repos, worktrees: worktrees)
        let rows = WorkspaceTree.rows(tree, collapsed: collapsedIDs(tree))
        VStack(alignment: .leading, spacing: 0) {
            PanelBar(spacing: Theme.Space.s) {
                Image(systemName: WorkspaceStyle.symbol)
                    .font(.system(size: SidebarStyle.iconSize))
                    .foregroundStyle(.secondary)
                Text(verbatim: workspace.name)
                    .font(Theme.Font.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(workspace.scanRoot.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? workspace.name)
                Spacer(minLength: 0)
                CountBadge(count: workspace.repos.count)
                Menu {
                    WorkspaceMenu(workspace: workspace, rename: { renaming = true })
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Workspace actions")
            }

            if workspace.repos.isEmpty {
                EmptyState(symbol: WorkspaceStyle.symbol, title: "No repositories yet",
                           message: "Add a repository, or a folder to look for repositories in.") {
                    Button("Add Repository…") { WorkspaceActions.addRepository(to: workspace.id) }
                }
            } else {
                List(selection: $selection) {
                    ForEach(rows) { row in
                        rowView(row)
                            .tag(row.id)
                            .selectionDisabled(row.node.kind == .folder || missing.contains(row.id))
                            .listRowInsets(SidebarStyle.rowInsets)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, Theme.Metrics.rowHeight)
                .environment(\.sidebarRowSize, .small)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let row = rows.first(where: { $0.id == id }) { menu(for: row.node) }
                }
            }
        }
        .sheet(isPresented: $renaming) { RenameWorkspaceSheet(workspace: workspace) }
        .onChange(of: selection) { _, id in
            guard let id, id != current, rows.contains(where: { $0.id == id && $0.node.kind != .folder }) else { return }
            select(id)
        }
        .onChange(of: current) { _, new in selection = new }
        .onAppear {
            selection = current
            toggled = Set(UserDefaults.standard.stringArray(forKey: Prefs.Key.workspaceCollapsed(workspace.id)) ?? [])
        }
        // Worktrees come and go: read them again whenever this tab switches or comes to the front.
        .task(id: ReloadKey(repos: workspace.repos, current: current)) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
        }
    }

    private struct ReloadKey: Hashable {
        let repos: [String]
        let current: String?
    }

    private func reload() async {
        let repos = workspace.repos
        worktrees = await WorkspaceDisk.worktrees(of: repos)
        missing = Set(repos.filter { !WorkspaceDisk.exists($0) })
    }

    // MARK: Open and closed

    private func isOpen(_ node: WorkspaceTree.Node) -> Bool {
        // The repository of the worktree shown here stays open, so the current row is visible.
        if node.kind == .repo, let current, node.children.contains(where: { $0.id == current }) { return true }
        return (node.kind == .folder) != toggled.contains(node.id)
    }

    private func collapsedIDs(_ nodes: [WorkspaceTree.Node]) -> Set<String> {
        var ids = Set<String>()
        for node in nodes where !node.children.isEmpty {
            if !isOpen(node) { ids.insert(node.id) }
            ids.formUnion(collapsedIDs(node.children))
        }
        return ids
    }

    private func toggle(_ id: String) {
        if toggled.contains(id) { toggled.remove(id) } else { toggled.insert(id) }
        UserDefaults.standard.set(Array(toggled), forKey: Prefs.Key.workspaceCollapsed(workspace.id))
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: WorkspaceTree.Row) -> some View {
        let node = row.node
        let gone = missing.contains(node.id)
        let isCurrent = node.id == current
        SidebarRowLayout(depth: row.depth) {
            if row.hasChildren {
                if node.kind == .folder {
                    DisclosureChevron(expanded: isOpen(node))
                } else {
                    // Only the chevron: a click on the rest of the row selects the repository.
                    DisclosureChevron(expanded: isOpen(node))
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(node.id) }
                }
            }
        } content: {
            SidebarIcon(symbol: gone ? "exclamationmark.triangle" : WorkspaceStyle.symbol(node.kind),
                        color: isCurrent ? .accentColor : .secondary)
            Text(verbatim: node.name)
                .fontWeight(isCurrent ? .semibold : .regular)
                .truncationMode(.middle)
                .foregroundStyle(gone ? .tertiary : .primary)
            Spacer(minLength: 0)
        }
        .modifier(CurrentBand(active: isCurrent))
        .help(gone ? String(localized: "\(node.id) is gone") : (node.id as NSString).abbreviatingWithTildeInPath)
        // Folders open and close on a click anywhere on the row. Other rows get
        // no gesture at all: one would swallow the click the list selects with.
        .modifier(FolderToggle(active: node.kind == .folder) { toggle(node.id) })
    }

    private struct FolderToggle: ViewModifier {
        let active: Bool
        let toggle: () -> Void

        func body(content: Content) -> some View {
            if active {
                content.onTapGesture(perform: toggle)
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private func menu(for node: WorkspaceTree.Node) -> some View {
        let gone = missing.contains(node.id)
        if node.kind != .folder {
            Button("Open") { select(node.id) }.disabled(gone || node.id == current)
            Button("Open in New Tab") { openInNewTab(node.id) }.disabled(gone)
            Divider()
            Button("Open in Terminal") { External.openTerminal(node.id) }.disabled(gone)
            Button("Open in Editor") { External.openEditor(node.id) }.disabled(gone)
        }
        Button("Reveal in Finder") { External.reveal(node.id) }.disabled(gone)
        if node.kind == .repo {
            Divider()
            Button("Remove from Workspace") {
                WorkspaceStore.shared.update(workspace.id) { $0.remove(node.id) }
            }
        }
    }
}

enum WorkspaceStyle {
    static let symbol = "square.stack.3d.up"

    static func symbol(_ kind: WorkspaceTree.Kind) -> String {
        switch kind {
        case .folder: "folder"
        case .repo: "book.closed"
        case .worktree: "arrow.triangle.branch"
        }
    }
}

/// The workspace's own actions: header menu of the column.
struct WorkspaceMenu: View {
    let workspace: Workspace
    let rename: () -> Void

    var body: some View {
        Button("Add Repository…") { WorkspaceActions.addRepository(to: workspace.id) }
        if workspace.scanRoot != nil {
            Button("Scan Folder Again") { WorkspaceActions.rescan(workspace.id) }
        }
        Button("Rename…", action: rename)
        if let root = workspace.scanRoot {
            Button("Reveal in Finder") { External.reveal(root) }
        }
        Divider()
        Button("Delete Workspace…") { WorkspaceActions.confirmDelete(workspace.id) }
    }
}

/// Workspace changes started from menus, with their file pickers and alerts.
@MainActor
enum WorkspaceActions {
    /// A repository, or a folder whose repositories are added (Settings' scan depth).
    static func addRepository(to id: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = L("Choose repositories, or folders to look for repositories in")
        guard panel.runModal() == .OK else { return }
        let chosen = panel.urls.map(\.path)
        Task {
            var found: [String] = []
            for folder in chosen {
                if let repo = await RepoLocator.resolve(folder) {
                    found.append(realPath(repo))
                } else {
                    found += await WorkspaceDisk.scan(folder, depth: Prefs.scanDepth)
                }
            }
            let new = withoutShownWorktrees(found, in: id)
            var added = 0
            WorkspaceStore.shared.update(id) { added = $0.add(new) }
            if found.isEmpty {
                inform(L("No git repositories found"), chosen.joined(separator: "\n"))
            } else if added == 0 {
                inform(L("Already in this workspace"), found.joined(separator: "\n"))
            }
        }
    }

    /// Looks through the folder the workspace was made from again and adds new
    /// repositories, but not the ones removed from it by hand.
    static func rescan(_ id: String) {
        guard let ws = WorkspaceStore.shared.workspace(id), let root = ws.scanRoot else { return }
        Task {
            let scanned = await WorkspaceDisk.scan(root, depth: ws.scanDepth ?? Prefs.scanDepth)
            let found = withoutShownWorktrees(scanned, in: id)
            var added = 0
            WorkspaceStore.shared.update(id) { added = $0.addScanned(found) }
            inform(added == 0 ? L("No new repositories found") : added == 1 ? L("Added 1 repository")
                   : String(localized: "Added \(added) repositories"),
                   (root as NSString).abbreviatingWithTildeInPath)
        }
    }

    /// `found` without the linked worktrees the workspace's tree shows anyway,
    /// below a repository that is in the workspace or in `found`.
    private static func withoutShownWorktrees(_ found: [String], in id: String) -> [String] {
        RepoScan.withoutLinkedWorktrees(found, besides: WorkspaceStore.shared.workspace(id)?.repos ?? [],
                                        mainWorktree: WorkspaceDisk.mainWorktree(of:))
    }

    static func confirmDelete(_ id: String) {
        guard let ws = WorkspaceStore.shared.workspace(id) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete the workspace \(ws.name)?")
        alert.informativeText = L("Only the list goes. The repositories stay where they are, and open tabs keep showing theirs.")
        alert.addButton(withTitle: L("Delete Workspace"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        WorkspaceStore.shared.delete(id)
    }

    private static func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

struct RenameWorkspaceSheet: View {
    let workspace: Workspace
    @State private var name: String

    init(workspace: Workspace) {
        self.workspace = workspace
        _name = State(initialValue: workspace.name)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SheetScaffold(title: "Rename Workspace", confirmTitle: "Rename", confirmDisabled: trimmed.isEmpty || trimmed == workspace.name) {
            let new = trimmed
            WorkspaceStore.shared.update(workspace.id) { $0.name = new }
        } content: {
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
        }
    }
}
