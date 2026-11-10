import GitCoworkCore
import SwiftUI

/// Right panel for a stash picked in the sidebar: what it's called, when and
/// where it was made, its files (click one for the diff), and Pop / Apply /
/// Delete. Built from the same pieces as the commit panel.
struct StashPanel: View {
    let model: RepoModel
    let sha: String

    @State private var contents: StashContents?
    @State private var failed = false
    @State private var collapsed: Set<String> = []
    @AppStorage(FileViewMode.storageKey) private var mode: FileViewMode = .path
    @AppStorage(FileSortMode.storageKey) private var sort: FileSortMode = .path

    private var stash: Stash? { model.stashes.first { $0.sha == sha } }

    var body: some View {
        VStack(spacing: 0) {
            PanelBar(spacing: Theme.Space.s) {
                Text("Stash").font(Theme.Font.title)
                if let stash {
                    Text(verbatim: stash.selector)
                        .font(Theme.Font.mono)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Space.s)
            }
            if !model.status.isClean {
                WorkingCopyBanner(count: model.status.changeCount) {
                    model.selection = .workingCopy
                    model.openDiff = nil
                }
            }
            if let stash, let contents {
                content(stash, contents)
            } else if stash == nil || failed {
                // Only for a moment after Pop or Delete: the model then moves on.
                EmptyState(symbol: "tray", title: "This stash is gone",
                           message: "It was applied or deleted.")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: sha) { await load() }
    }

    private func load() async {
        guard let stash else { return }
        failed = false
        let loaded = await model.stashContents(stash)
        guard !Task.isCancelled else { return }
        contents = loaded
        failed = loaded == nil
    }

    private func content(_ stash: Stash, _ c: StashContents) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionGap) {
                MessageCard(subject: stash.title ?? L("Stashed changes"),
                            text: stash.branch.map { String(localized: "On \($0)") } ?? "")
                AuthorBlock(detail: c.changes, reveal: model.reveal)
                HStack(spacing: Theme.Space.m) {
                    Button("Pop") { Task { await model.popStash(stash) } }
                        .buttonStyle(ActionButtonStyle.primary())
                        .help("Put the changes back and delete the stash")
                    Button("Apply") { Task { await model.applyStash(stash) } }
                        .buttonStyle(ActionButtonStyle.secondary())
                        .help("Put the changes back and keep the stash")
                    Spacer(minLength: Theme.Space.s)
                    Button("Delete…") { model.dropStash(stash) }
                        .buttonStyle(ActionButtonStyle.secondary(Theme.Status.deleted))
                }
                .disabled(model.busy != nil)
            }
            .padding(Theme.Metrics.panelPadding)

            Divider()
            HStack(spacing: Theme.Space.m) {
                if c.files.isEmpty {
                    Text("No file changes").font(Theme.Font.small).foregroundStyle(.secondary)
                } else {
                    ChangeSummary(files: c.files)
                }
                Spacer(minLength: Theme.Space.s)
                FileViewControls()
            }
            .padding(.horizontal, Theme.Metrics.panelPadding)
            .frame(height: InspectorStyle.subheaderHeight)
            Divider()

            fileList(c)
        }
    }

    private func fileList(_ c: StashContents) -> some View {
        let items = FileTree.items(c.files, mode: mode, sort: sort, collapsed: collapsed, scope: "stash")
        return List(selection: selectedFile(c)) {
            ForEach(items) { item in
                switch item {
                case .folder(let f):
                    FolderRow(folder: f) { FileTree.toggle(f.id, in: &collapsed) }
                        .selectionDisabled()
                        .contextMenu {
                            Button("Copy Path") { External.copy(f.path) }
                        }
                        .listRowSeparator(.hidden)
                case .file(let change, let depth):
                    FileRow(change: change, depth: depth, showDirectory: mode == .path)
                        .tag(change.id)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, Theme.Metrics.rowHeight)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let f = c.files.first(where: { $0.id == id }) {
                Button("Show Diff") { model.openDiff = .commit(c.source(of: f), f) }
                Divider()
                Button("Copy Path") { External.copy(f.path) }
            }
        }
    }

    private func selectedFile(_ c: StashContents) -> Binding<String?> {
        Binding(
            get: {
                if case .commit(let d, let f) = model.openDiff, c.holds(d) { return f.id }
                return nil
            },
            set: { id in
                guard let id, let f = c.files.first(where: { $0.id == id }) else { return }
                model.openDiff = .commit(c.source(of: f), f)
            })
    }
}
