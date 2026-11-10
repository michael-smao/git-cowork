import AppKit
import GitCoworkCore
import SwiftUI

/// Routes a SheetKind to its sheet.
struct RepoSheet: View {
    let model: RepoModel
    let kind: SheetKind
    let openInNewTab: (String) -> Void

    var body: some View {
        switch kind {
        case .newBranch(let from, let label): NewBranchSheet(model: model, start: from, startLabel: label)
        case .newTag(let sha): NewTagSheet(model: model, sha: sha)
        case .renameBranch(let name): RenameBranchSheet(model: model, old: name)
        case .addWorktree(let base): AddWorktreeSheet(model: model, base: base, openInNewTab: openInNewTab)
        case .stash: StashSheet(model: model)
        case .newTask(let status): NewTaskSheet(model: model, status: status)
        case .requestReview(let branch): RequestReviewSheet(model: model, branch: branch)
        case .createPull(let branch): CreatePullSheet(model: model, branch: branch)
        case .team: TeamSheet(model: model)
        case .pushTarget(let branch): PushTargetSheet(model: model, branch: branch)
        case .addRemote(let branch): AddRemoteSheet(model: model, thenPush: branch)
        case .editRemote(let name): EditRemoteSheet(model: model, old: name)
        case .identity: IdentitySheet(model: model)
        }
    }
}


struct NewBranchSheet: View {
    let model: RepoModel
    let start: String
    let startLabel: String
    @State private var name = ""
    @State private var checkout = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var taken: Bool { model.localBranches.contains { $0.name == name } }

    var body: some View {
        SheetScaffold(title: "New Branch", confirmTitle: "Create Branch",
                      confirmDisabled: !RefName.isValid(name) || taken || model.busy != nil, error: error, dismissOnConfirm: false) {
            Task {
                if await model.createBranch(name, from: start, checkout: checkout, quiet: true) { dismiss() } else { error = model.lastProblemText }
            }
        } content: {
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
            if taken { NameTaken(text: String(localized: "A branch named \(name) already exists.")) }
            Text("Starts from \(startLabel)").font(Theme.Font.small).foregroundStyle(.secondary)
            Toggle("Check out after creating", isOn: $checkout).toggleStyle(.checkbox)
        }
    }
}

struct NewTagSheet: View {
    let model: RepoModel
    let sha: String
    @State private var name = ""
    @State private var message = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var taken: Bool { model.tags.contains { $0.name == name } }

    var body: some View {
        SheetScaffold(title: "New Tag", confirmTitle: "Create Tag", confirmDisabled: !RefName.isValid(name) || taken || model.busy != nil,
                      error: error, dismissOnConfirm: false) {
            Task {
                if await model.createTag(name, at: sha, message: message, quiet: true) { dismiss() } else { error = model.lastProblemText }
            }
        } content: {
            TextField("Tag name, e.g. v1.2.0", text: $name).textFieldStyle(.roundedBorder)
            if taken { NameTaken(text: String(localized: "A tag named \(name) already exists.")) }
            TextField("Message (optional, makes an annotated tag)", text: $message).textFieldStyle(.roundedBorder)
            Text("On commit \(String(sha.prefix(7)))").font(Theme.Font.small).foregroundStyle(.secondary)
        }
    }
}

struct RenameBranchSheet: View {
    let model: RepoModel
    let old: String
    @State private var name: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: RepoModel, old: String) {
        self.model = model
        self.old = old
        _name = State(initialValue: old)
    }

    private var taken: Bool { name != old && model.localBranches.contains { $0.name == name } }

    var body: some View {
        SheetScaffold(title: String(localized: "Rename \(old)"), confirmTitle: "Rename",
                      confirmDisabled: !RefName.isValid(name) || name == old || taken || model.busy != nil,
                      error: error, dismissOnConfirm: false) {
            Task {
                if await model.renameBranch(old, to: name, quiet: true) { dismiss() } else { error = model.lastProblemText }
            }
        } content: {
            TextField("New name", text: $name).textFieldStyle(.roundedBorder)
            if taken { NameTaken(text: String(localized: "A branch named \(name) already exists.")) }
        }
    }
}

struct StashSheet: View {
    let model: RepoModel
    @State private var message = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: "Stash Changes", confirmTitle: "Stash", confirmDisabled: model.busy != nil,
                      error: error, dismissOnConfirm: false) {
            Task {
                if await model.stash(message: message, quiet: true) { dismiss() } else { error = model.lastProblemText }
            }
        } content: {
            TextField("Message (optional)", text: $message).textFieldStyle(.roundedBorder)
            Text("Stashes all changes, including new files, and leaves a clean working copy.")
                .font(Theme.Font.small).foregroundStyle(.secondary)
        }
    }
}

struct AddWorktreeSheet: View {
    let model: RepoModel
    let openInNewTab: (String) -> Void

    enum Mode: String, CaseIterable { case newBranch = "New branch", existing = "Existing branch" }

    @State private var mode: Mode
    @State private var branch: String
    @State private var base: String
    @State private var existing: String
    @State private var path = ""
    @State private var pathEdited = false
    @State private var openAfter = true

    init(model: RepoModel, base: String?, openInNewTab: @escaping (String) -> Void) {
        self.model = model
        self.openInNewTab = openInNewTab
        let free = model.localBranches.map(\.name).filter { name in !model.worktrees.contains { $0.branch == name } }
        let baseRef = model.refs.first { $0.name == base }
        // A remote branch as base: suggest a local branch of the same name.
        let suggested = baseRef?.kind == .remoteBranch ? baseRef!.branchNameWithoutRemote : ""
        let startExisting = baseRef?.kind == .localBranch && free.contains(base ?? "")
        _mode = State(initialValue: startExisting ? .existing : .newBranch)
        _branch = State(initialValue: suggested)
        _base = State(initialValue: base ?? model.currentBranch ?? "HEAD")
        _existing = State(initialValue: startExisting ? base! : (free.first ?? ""))
    }

    private var freeBranches: [String] {
        model.localBranches.map(\.name)
            .filter { name in !model.worktrees.contains { $0.branch == name } }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var targetBranch: String { mode == .newBranch ? branch : existing }

    private var valid: Bool {
        guard !path.isEmpty, !FileManager.default.fileExists(atPath: path) else { return false }
        if mode == .newBranch {
            return RefName.isValid(branch) && !model.localBranches.contains { $0.name == branch }
        }
        return !existing.isEmpty
    }

    var body: some View {
        SheetScaffold(title: "Add Worktree", confirmTitle: "Create Worktree", confirmDisabled: !valid || model.busy != nil) {
            let p = path, newBranch = mode == .newBranch ? branch : nil, start = mode == .newBranch ? base : existing
            let open = openAfter
            Task {
                if await model.addWorktree(path: p, newBranch: newBranch, base: start), open {
                    openInNewTab(p)
                }
            }
        } content: {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                if mode == .newBranch {
                    TextField("Branch", text: $branch, prompt: Text("e.g. claude/fix-login"))
                    TextField("Based on", text: $base)
                } else {
                    Picker("Branch", selection: $existing) {
                        ForEach(freeBranches, id: \.self) { Text($0) }
                    }
                }
                HStack {
                    TextField("Folder", text: Binding(get: { path }, set: { path = $0; pathEdited = true }))
                    Button("Choose…") { choosePath() }
                }
            }
            .formStyle(.columns)

            if FileManager.default.fileExists(atPath: path) && !path.isEmpty {
                ErrorText(L("That folder already exists"))
            }
            Toggle("Open in a new tab", isOn: $openAfter).toggleStyle(.checkbox)
        }
        .onAppear { updatePath() }
        .onChange(of: targetBranch) { updatePath() }
    }

    private func updatePath() {
        guard !pathEdited else { return }
        path = targetBranch.isEmpty ? "" : model.suggestedWorktreePath(branch: targetBranch)
    }

    private func choosePath() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            pathEdited = true
        }
    }
}

struct CloneSheet: View {
    let onCloned: (String) -> Void
    @State private var url = ""
    @State private var parent = CloneSheet.defaultParent
    @State private var accounts = AccountStore.shared.accounts
    /// The account whose list the URL came from; nil for a typed URL.
    @State private var listAccount: HostAccount?
    @State private var running = false
    @State private var error: String?
    /// The destination already holds a git repository: offer to open it.
    @State private var existingRepo: String?
    @Environment(\.dismiss) private var dismiss

    static var defaultParent: String {
        let gh = NSHomeDirectory() + "/Documents/GitHub"
        return FileManager.default.fileExists(atPath: gh) ? gh : NSHomeDirectory()
    }

    private var folderName: String { RemoteLinks.cloneFolderName(url) }

    var body: some View {
        // Stays open while cloning; clone() closes it when done.
        SheetScaffold(title: "Clone Repository", confirmTitle: "Clone", confirmDisabled: folderName.isEmpty,
                      error: error, monoError: true, busy: running ? "Cloning…" : nil,
                      dismissOnConfirm: false, width: accounts.isEmpty ? 480 : 540) {
            clone(url)
        } content: {
            if !accounts.isEmpty {
                CloneRepoList(accounts: accounts, url: $url, listAccount: $listAccount) { picked in
                    guard !running else { return }
                    url = picked
                    clone(picked)
                }
                Text("Or Enter a URL").font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            TextField("git@github.com:org/repo.git or https://…", text: $url)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text(parent).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let u = panel.url { parent = u.path }
                }
            }
            .font(Theme.Font.small)
            if let existingRepo {
                SheetNotice(symbol: "folder.fill", color: .accentColor,
                            text: String(localized: "\(existingRepo) already holds a git repository.")) {
                    Button("Open It") {
                        dismiss()
                        onCloned(existingRepo)
                    }
                    .buttonStyle(ActionButtonStyle.secondary())
                }
            } else if !folderName.isEmpty {
                Text("Clones into \(destination(for: folderName))").font(Theme.Font.small).foregroundStyle(.secondary)
            }
        }
    }

    /// `parent/name`, or `name-2` … when a folder of that name exists (a
    /// repository there is offered for opening before it gets this far).
    private func destination(for name: String) -> String {
        WorktreePath.unique(parent + "/" + name)
    }

    private func clone(_ source: String) {
        let name = RemoteLinks.cloneFolderName(source)
        guard !name.isEmpty else { return }
        error = nil
        let taken = parent + "/" + name
        // Same folder, already a repository (cloned before): open it instead of failing.
        if FileManager.default.fileExists(atPath: taken + "/.git") {
            existingRepo = taken
            return
        }
        existingRepo = nil
        running = true
        let dest = destination(for: name)
        Task {
            do {
                try await RepoModel.clone(source.trimmingCharacters(in: .whitespaces), into: dest, picked: listAccount)
                running = false
                dismiss()
                onCloned(dest)
            } catch {
                running = false
                self.error = error.localizedDescription
            }
        }
    }
}

/// "A branch named x already exists." under a name field.
struct NameTaken: View {
    let text: String
    var body: some View {
        Text(verbatim: text).font(Theme.Font.small).foregroundStyle(Theme.Status.error)
    }
}
