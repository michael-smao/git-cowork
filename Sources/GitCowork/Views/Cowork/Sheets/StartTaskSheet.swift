import GitCoworkCore
import SwiftUI

/// "Start Task" for a task shared between repositories: tick the ones to
/// start it in. Each gets the same branch. This repository (and others
/// loaded in a tab) check it out like Start Task always did; a repository
/// that isn't loaded gets the branch without switching its checkout. With
/// "Each in its own worktree" every one gets its own folder and tab.
struct StartTaskSheet: View {
    let model: RepoModel
    let taskID: String
    let openInNewTab: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var worktree: Bool
    @State private var picked: Set<String> = []
    @State private var working = false
    @State private var error: String?

    init(model: RepoModel, taskID: String, worktree: Bool, openInNewTab: @escaping (String) -> Void) {
        self.model = model
        self.taskID = taskID
        self.openInNewTab = openInNewTab
        _worktree = State(initialValue: worktree)
    }

    /// One of the task's repositories, and how it can be reached here.
    private struct Target: Identifiable {
        enum Place { case here, loaded(RepoModel), folder(String), missing }
        let id: String
        let place: Place
        var name: String { RepoID.name(id) }
        var available: Bool { if case .missing = place { false } else { true } }
    }

    private var task: CoworkTask? { model.cowork.task(taskID) }
    private var branch: String? { task.flatMap(TaskStart.branchName(for:)) }

    private var targets: [Target] {
        guard let task, let mine = model.cowork.repoID else { return [] }
        let others = task.repos.filter { $0.lowercased() != mine.lowercased() }
        return [Target(id: mine, place: .here)] + others.map { id in
            let key = id.lowercased()
            if let m = LiveRepos.shared.models.first(where: { $0.isLoaded && $0.cowork.repoID?.lowercased() == key }) {
                return Target(id: id, place: .loaded(m))
            }
            if let known = CoworkHub.shared.known.first(where: { $0.id.lowercased() == key }) {
                return Target(id: id, place: .folder(known.path))
            }
            return Target(id: id, place: .missing)
        }
    }

    var body: some View {
        SheetScaffold(title: String(localized: "Start \(taskID)"), confirmTitle: L("Start"),
                      confirmDisabled: working || picked.isEmpty || branch == nil || model.busy != nil,
                      error: error, busy: working ? "Starting…" : nil, dismissOnConfirm: false) {
            start()
        } content: {
            if let branch {
                Text("Branch \(branch) in:")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(targets) { target in
                    Toggle(isOn: Binding(get: { picked.contains(target.id) },
                                         set: { if $0 { picked.insert(target.id) } else { picked.remove(target.id) } })) {
                        HStack(spacing: Theme.Space.s) {
                            Text(verbatim: target.name)
                            Text(note(target)).font(Theme.Font.small).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!target.available)
                    .help(target.id)
                }
            }
            Toggle("Each in its own worktree", isOn: $worktree).toggleStyle(.checkbox)
        }
        .onAppear { picked = Set(targets.filter(\.available).map(\.id)) }
    }

    private func note(_ target: Target) -> String {
        switch target.place {
        case .here: L("this tab, checked out here")
        case .loaded: L("open in another tab, checked out there")
        case .folder: worktree ? L("on this Mac") : L("on this Mac, branch only (no checkout)")
        case .missing: L("not on this Mac")
        }
    }

    private func start() {
        guard let branch else { return }
        let chosen = targets.filter { picked.contains($0.id) }
        error = nil
        working = true
        Task {
            defer { working = false }
            var failures: [String] = []
            var startedHere = false
            for target in chosen {
                switch target.place {
                case .here:
                    if worktree {
                        if let path = await model.startTaskInWorktree(taskID) {
                            startedHere = true
                            if path != model.root.path { openInNewTab(path) }
                        } else { failures.append(target.name) }
                    } else {
                        if await model.startTaskHere(taskID) { startedHere = true } else { failures.append(target.name) }
                    }
                case .loaded(let other):
                    if worktree {
                        if let path = await other.startTaskInWorktree(taskID) { openInNewTab(path) } else { failures.append(target.name) }
                    } else if await !other.startTaskHere(taskID) {
                        failures.append(target.name)
                    }
                case .folder(let path):
                    let result = await CoworkHub.shared.startTask(branch: branch, inRepoAt: path, worktree: worktree)
                    if let message = result.error {
                        failures.append("\(target.name): \(message)")
                    } else if worktree, let folder = result.path {
                        openInNewTab(folder)
                    }
                case .missing:
                    break
                }
            }
            // Linked and In Progress in every copy (CoworkHub copies the change).
            if !startedHere { await model.cowork.markStarted(taskID, branch: branch) }
            if failures.isEmpty {
                dismiss()
            } else {
                error = String(localized: "Couldn't start it in: \(failures.joined(separator: ", "))")
                    + (model.lastProblemText.map { "\n" + $0 } ?? "")
            }
        }
    }
}
