import AppKit
import GitCoworkCore
import SwiftUI

/// File › Scan Folder…: finds the repositories in a folder and keeps them as
/// a workspace. Shows what it finds while the depth changes. A folder that
/// already has a workspace offers that one instead.
struct ScanFolderSheet: View {
    /// The workspace to show: the new one, or the folder's existing one.
    let onOpen: (String) -> Void
    @State private var folder: String
    @State private var name: String
    @State private var depth = Prefs.scanDepth
    /// Nil while scanning.
    @State private var found: [String]?

    private enum Layout {
        static let listHeight: CGFloat = 140
    }

    init(folder: String, onOpen: @escaping (String) -> Void) {
        self.onOpen = onOpen
        _folder = State(initialValue: folder)
        _name = State(initialValue: (folder as NSString).lastPathComponent)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    @Environment(\.dismiss) private var dismiss

    private var existing: Workspace? { WorkspaceStore.shared.workspace(scanRoot: folder) }

    var body: some View {
        SheetScaffold(title: "Scan Folder", confirmTitle: "Create Workspace",
                      confirmDisabled: trimmedName.isEmpty || found?.isEmpty != false || existing != nil,
                      busy: found == nil ? "Looking for repositories…" : nil) {
            let ws = WorkspaceStore.shared.create(name: trimmedName, repos: found ?? [], scanRoot: realPath(folder), scanDepth: depth)
            onOpen(ws.id)
        } content: {
            HStack {
                Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") { choose() }
            }
            .font(Theme.Font.small)
            if let existing {
                SheetNotice(symbol: WorkspaceStyle.symbol, color: .accentColor,
                            text: String(localized: "This folder already has the workspace \(existing.name).")) {
                    Button("Open It") {
                        dismiss()
                        onOpen(existing.id)
                    }
                    .buttonStyle(ActionButtonStyle.secondary())
                }
            }
            TextField("Workspace name", text: $name).textFieldStyle(.roundedBorder)
            Stepper(value: $depth, in: RepoScan.depthRange) {
                Text(depth == 1 ? L("Look in subfolders, 1 level deep") : String(localized: "Look in subfolders, \(depth) levels deep"))
            }
            result
        }
        .task(id: ScanKey(folder: folder, depth: depth)) {
            found = nil
            let repos = await WorkspaceDisk.scan(folder, depth: depth)
            guard !Task.isCancelled else { return }
            found = repos
        }
    }

    private struct ScanKey: Hashable {
        let folder: String
        let depth: Int
    }

    @ViewBuilder
    private var result: some View {
        if let found {
            if found.isEmpty {
                Text("No git repositories found. Try looking deeper.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
            } else {
                Text(found.count == 1 ? L("Found 1 repository") : String(localized: "Found \(found.count) repositories"))
                    .font(Theme.Font.small).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(found, id: \.self) { repo in
                            Text(verbatim: relative(repo))
                                .font(Theme.Font.small)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.s)
                }
                .frame(maxHeight: Layout.listHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.cardFill))
            }
        }
    }

    /// "group/repo" below the chosen folder.
    private func relative(_ repo: String) -> String {
        let base = realPath(folder)
        guard repo.hasPrefix(base + "/") else { return (repo as NSString).lastPathComponent }
        return String(repo.dropFirst(base.count + 1))
    }

    private func choose() {
        guard let picked = FolderPicker.choose(message: L("Choose a folder to look for repositories in")) else { return }
        // A name the person didn't change follows the folder.
        if name == (folder as NSString).lastPathComponent { name = (picked as NSString).lastPathComponent }
        folder = picked
    }
}

enum FolderPicker {
    static func choose(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
