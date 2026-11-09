import CoworkKit
import Foundation
import GitCoworkCore

/// Cowork actions that also touch git (branches for tasks). Which branch and
/// which git command is TaskStart (GitCoworkCore), the same as `git cowork start`.
extension RepoModel {
    /// The local or remote branch a task is linked to, if it exists here.
    /// A linked name that isn't a valid branch name counts as not linked.
    func linkedBranch(of task: CoworkTask) -> Ref? {
        guard let b = task.linkedBranch else { return nil }
        return branch(named: b)
    }

    /// "Start Task": checks out the task's branch (an existing local one, else
    /// tracking the remote one, else a new one from the base branch), links
    /// it, moves the task to In Progress and assigns it to me. When another
    /// worktree has the branch checked out, starts the task and opens that
    /// worktree instead.
    func startTask(_ id: String) {
        guard let t = cowork.task(id) else { return }
        guard let name = TaskStart.branchName(for: t) else {
            alert = AlertItem(title: L("Start task failed"), message: String(localized: "\(t.id) has no usable branch name."))
            return
        }
        if let wt = worktree(holding: name) {
            guard let openWorktree else {
                _ = refuseIfCheckedOutElsewhere(name)
                return
            }
            // Saved first: this window may show the other worktree next.
            Task {
                await cowork.markStarted(id, branch: name)
                openWorktree(wt.path)
            }
            return
        }
        let args = TaskStart.plan(branch: name, hasLocal: localBranch(named: name) != nil,
                                  remoteBranch: remoteBranch(named: name)?.name, base: baseBranch()?.ref ?? "HEAD")
        Task {
            guard await perform("Start task", args) else { return }
            await cowork.markStarted(id, branch: name)
        }
    }

    /// The worktree that has the task's branch checked out, if any.
    func worktree(of task: CoworkTask) -> Worktree? {
        guard let b = task.linkedBranch else { return nil }
        return worktrees.first { $0.branch == b }
    }

    /// "Start in New Worktree": gives the task its own folder (next to the
    /// main checkout) on its own branch, so an agent or a second person can
    /// work on it without touching this checkout. Calls `open` with the new
    /// folder, e.g. to show it in a new tab. Reuses an existing worktree.
    func startTaskInWorktree(_ id: String, open: @escaping (String) -> Void) {
        Task { if let path = await startTaskInWorktree(id) { open(path) } }
    }

    /// Returns the worktree folder, or nil if it couldn't be created.
    func startTaskInWorktree(_ id: String) async -> String? {
        guard let t = cowork.task(id) else { return nil }
        if let wt = worktree(of: t) { return wt.path }
        guard let name = TaskStart.branchName(for: t) else {
            alert = AlertItem(title: L("Start task failed"), message: String(localized: "\(t.id) has no usable branch name."))
            return nil
        }
        var path = suggestedWorktreePath(branch: name)
        if let existing = worktrees.first(where: { realPath($0.path) == realPath(path) }) {
            // Already a worktree of this repository (on another branch): say so rather than fail.
            problem = GitProblem(title: L("That worktree already exists"),
                                 message: String(localized: "\(path) is already a worktree, on \(existing.branch ?? L("detached")). Open it, or remove it first."),
                                 actions: [.init(title: L("Open It"), role: .primary) { [weak self] in self?.openWorktree?(existing.path) }])
            return nil
        }
        if FileManager.default.fileExists(atPath: path) {
            path = WorktreePath.unique(path)
        }
        let args = TaskStart.plan(branch: name, hasLocal: localBranch(named: name) != nil,
                                  remoteBranch: remoteBranch(named: name)?.name, base: baseBranch()?.ref ?? "HEAD",
                                  worktreePath: path)
        guard await perform("Add worktree", args) else { return nil }
        await cowork.markStarted(id, branch: name)
        return path
    }
}

extension CoworkStore {
    /// Links the branch, moves the task to In Progress (top of the column)
    /// and assigns it to me if nobody has it (CoworkEdit.startedChange).
    func markStarted(_ id: String, branch: String) async {
        await updateTasks([id: CoworkEdit.startedChange(branch: branch, me: me.email, in: snapshot)],
                          message: "Start \(id)")
    }
}
