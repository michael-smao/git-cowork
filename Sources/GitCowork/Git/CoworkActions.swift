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

    /// A task shared with other repositories on this Mac: "Start Task" asks
    /// in which of them (StartTaskSheet). Otherwise it starts here.
    func startTask(_ id: String) {
        if isSharedHere(id) {
            sheet = .startTask(id, worktree: false)
        } else {
            Task { await startTaskHere(id) }
        }
    }

    /// Shared with at least one other repository this Mac has.
    func isSharedHere(_ id: String) -> Bool {
        guard let t = cowork.task(id), t.repos.count > 1, let mine = cowork.repoID?.lowercased() else { return false }
        let known = Set(CoworkHub.shared.known.map { $0.id.lowercased() })
        return t.repos.contains { $0.lowercased() != mine && known.contains($0.lowercased()) }
    }

    /// "Start Task" here: checks out the task's branch (an existing local one, else
    /// tracking the remote one, else a new one from the base branch), links
    /// it, moves the task to In Progress and assigns it to me. When another
    /// worktree has the branch checked out, starts the task and opens that
    /// worktree instead. Returns false when it failed.
    @discardableResult
    func startTaskHere(_ id: String) async -> Bool {
        guard let t = cowork.task(id) else { return false }
        guard let name = TaskStart.branchName(for: t) else {
            alert = AlertItem(title: L("Start task failed"), message: String(localized: "\(t.id) has no usable branch name."))
            return false
        }
        if let wt = worktree(holding: name) {
            guard let openWorktree else {
                _ = refuseIfCheckedOutElsewhere(name)
                return false
            }
            // Saved first: this window may show the other worktree next.
            await cowork.markStarted(id, branch: name)
            openWorktree(wt.path)
            return true
        }
        let args = TaskStart.plan(branch: name, hasLocal: localBranch(named: name) != nil,
                                  remoteBranch: remoteBranch(named: name)?.name, base: baseBranch()?.ref ?? "HEAD")
        guard await perform("Start task", args) else { return false }
        await cowork.markStarted(id, branch: name)
        return true
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
        if isSharedHere(id) {
            sheet = .startTask(id, worktree: true)
            return
        }
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

extension CoworkHub {
    /// Starts a shared task in a repository that isn't loaded here: makes the
    /// branch without switching that checkout, or with `worktree` adds a
    /// worktree for it. Returns the worktree's folder (or the repository's)
    /// and an error message if it failed.
    func startTask(branch: String, inRepoAt path: String, worktree: Bool) async -> (path: String?, error: String?) {
        let root = URL(fileURLWithPath: path)
        let git = GitRunner.shared
        let hasLocal = await git.tryLine(["rev-parse", "--verify", "-q", "refs/heads/\(branch)"], in: root) != nil
        let remotes = (await git.tryRun(["remote"], in: root) ?? "").split(separator: "\n").map(String.init)
        let remote = remotes.contains("origin") ? "origin" : remotes.first
        let remoteBranch: String? = await {
            guard let remote, await git.tryLine(["rev-parse", "--verify", "-q", "refs/remotes/\(remote)/\(branch)"], in: root) != nil else { return nil }
            return "\(remote)/\(branch)"
        }()
        var base = "HEAD"
        if let remote, let head = await git.tryLine(["rev-parse", "--abbrev-ref", "\(remote)/HEAD"], in: root), head != "\(remote)/HEAD" {
            base = head
        }
        var args: [String]
        var folder: String? = path
        if worktree {
            let target = WorktreePath.unique(WorktreePath.suggest(main: path, branch: branch))
            args = TaskStart.plan(branch: branch, hasLocal: hasLocal, remoteBranch: remoteBranch, base: base, worktreePath: target)
            folder = target
        } else if hasLocal {
            return (path, nil)
        } else if let remoteBranch {
            args = ["branch", "--track", "--end-of-options", branch, remoteBranch]
        } else {
            args = ["branch", "--no-track", "--end-of-options", branch, base]
        }
        do {
            _ = try await git.run(args, in: root, logged: true)
            return (folder, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}
