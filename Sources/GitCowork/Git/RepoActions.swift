import Foundation
import GitCoworkCore

/// Everything the user can do to a repo. Each action is one or two plain git
/// commands; they all show up in the command log.
extension RepoModel {
    /// Runs a git command that changes the repo, then refreshes.
    /// Errors are shown as an alert with git's own message.
    @discardableResult
    func perform(_ label: String, _ args: [String], okCodes: Set<Int32> = [0]) async -> Bool {
        await waitForAutoFetch()
        guard beginBusy(label) else { return false }
        defer { endBusy(label) }
        if !UndoRecord.survives(args) { lastUndo = nil }
        do {
            try await git.run(args, in: root, logged: true, okCodes: okCodes)
            await refresh()
            return true
        } catch {
            await refresh()
            alert = AlertItem(title: String(localized: "\(label) failed"), message: error.localizedDescription)
            return false
        }
    }

    /// One git action at a time. Claims `busy` for `label`, or tells the user
    /// why nothing happened when another action is still running.
    func beginBusy(_ label: String) -> Bool {
        if let running = busy {
            if alert == nil {
                alert = AlertItem(title: String(localized: "\(label) not started"), message: String(localized: "Wait for \(running) to finish, then try again."))
            }
            return false
        }
        busy = label
        return true
    }

    /// Releases `busy` if `label` still holds it.
    func endBusy(_ label: String) {
        if busy == label { busy = nil }
    }

    // MARK: Remote

    func fetch() async {
        let ok = await perform("Fetch", ["fetch", "--all", "--prune"])
        noteRemoteAction(fetched: true, succeeded: ok)
        await syncCowork()
    }

    func pull(_ mode: PullMode = .default) async {
        let ok = await perform("Pull", mode.args)
        noteRemoteAction(fetched: true, succeeded: ok)
    }

    func push(force: Bool = false) async {
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        if status.upstream == nil {
            guard let remote = defaultRemote else {
                alert = AlertItem(title: "Push failed", message: "This repository has no remote.")
                return
            }
            args += ["-u", remote, "HEAD"]
        }
        if await perform(force ? "Force push" : "Push", args) {
            noteRemoteAction(fetched: false, succeeded: true)
        }
    }

    func confirmForcePush() {
        confirmation = Confirmation(
            title: String(localized: "Force push \(currentBranch ?? "HEAD")?"),
            message: "Uses --force-with-lease: it overwrites the remote branch, but only if nobody else pushed to it since your last fetch.",
            confirmTitle: "Force Push"
        ) { [weak self] in await self?.push(force: true) }
    }

    // MARK: Branches

    /// Worktree (other than this one) that has `branch` checked out.
    func worktree(holding branch: String) -> Worktree? {
        worktrees.first { $0.branch == branch && $0.path != root.path }
    }

    /// Alerts and returns true when `branch` is checked out in another worktree
    /// (git allows a branch in one worktree at a time).
    func refuseIfCheckedOutElsewhere(_ branch: String) -> Bool {
        guard let wt = worktree(holding: branch) else { return false }
        alert = AlertItem(title: String(localized: "\(branch) is checked out in another worktree"),
                          message: String(localized: "Git allows a branch in one worktree at a time. It's open in \(wt.path). Open that worktree instead, or create a new branch."))
        return true
    }

    func checkout(_ ref: Ref) async {
        let local = split(ref)?.branch ?? ref.name
        if ref.kind != .tag, refuseIfCheckedOutElsewhere(local) { return }
        let args: [String]
        switch ref.kind {
        case .localBranch:
            args = ["switch", "--end-of-options", ref.name]
        case .remoteBranch:
            if localBranch(named: local) != nil {
                args = ["switch", "--end-of-options", local]
            } else {
                args = ["switch", "--track", "-c", local, "--end-of-options", ref.name]
            }
        case .tag:
            args = ["switch", "--detach", "--end-of-options", ref.name]
        }
        await performUndoable(.checkout, "Checkout", args)
    }

    func checkoutCommit(_ sha: String) async {
        await performUndoable(.checkout, "Checkout", ["switch", "--detach", "--end-of-options", sha])
    }

    /// `--no-track`: a new branch made from e.g. origin/main shouldn't use main as its upstream.
    @discardableResult
    func createBranch(_ name: String, from start: String, checkout: Bool) async -> Bool {
        if checkout {
            return await perform("Create branch", ["switch", "--no-track", "-c", name, "--end-of-options", start])
        } else {
            return await perform("Create branch", ["branch", "--no-track", "--end-of-options", name, start])
        }
    }

    /// Pushes a branch that may not be checked out here, or is checked out in
    /// another worktree. A branch without an upstream gets one.
    @discardableResult
    func push(branch: String) async -> Bool {
        guard let args = BranchLookup.pushArguments(branch: branch, upstream: localBranch(named: branch)?.upstream,
                                                    remotes: remoteNames, fallbackRemote: defaultRemote) else {
            alert = AlertItem(title: "Push failed", message: "This repository has no remote.")
            return false
        }
        let pushed = await perform("Push", args)
        if pushed { noteRemoteAction(fetched: false, succeeded: true) }
        return pushed
    }

    func renameBranch(_ old: String, to new: String) async {
        await perform("Rename branch", ["branch", "-m", old, new])
    }

    func deleteBranch(_ ref: Ref) {
        if let s = split(ref) {
            let remote = s.remote, branch = s.branch
            confirmation = Confirmation(
                title: String(localized: "Delete \(ref.name) on \(remote)?"),
                message: "This deletes the branch on the server for everyone.",
                confirmTitle: "Delete Remote Branch"
            ) { [weak self] in
                await self?.perform("Delete remote branch", ["push", remote, "--delete", "refs/heads/\(branch)"])
            }
            return
        }
        Task {
            guard beginBusy("Delete branch") else { return }
            let r = await git.execute(["branch", "-d", ref.name], in: root)
            endBusy("Delete branch")
            if r.exitCode == 0 {
                CommandLog.shared.add(.init(args: ["branch", "-d", ref.name], directory: root, start: .now, duration: 0, result: r))
                lastUndo = nil
                await refresh()
                recordDeletedBranch(ref)
            } else if r.stderr.contains("not fully merged") {
                confirmation = Confirmation(
                    title: String(localized: "\(ref.name) is not fully merged"),
                    message: "Its commits aren't in your current branch or its upstream. Delete it anyway? Edit > Undo brings it back until you run another git command.",
                    confirmTitle: "Delete Anyway"
                ) { [weak self] in
                    guard let self, await perform("Delete branch", ["branch", "-D", ref.name]) else { return }
                    recordDeletedBranch(ref)
                }
            } else {
                alert = AlertItem(title: "Delete branch failed", message: GitError(command: "", result: r).localizedDescription)
            }
        }
    }

    func merge(_ name: String) async {
        let ok = await perform("Merge", ["merge", name], okCodes: [0])
        if !ok, !status.conflicted.isEmpty {
            alert = AlertItem(title: "Merge has conflicts",
                              message: "Resolve the conflicted files in Changes, then Continue, or Abort the merge.")
            selection = .workingCopy
        }
    }

    func rebase(onto name: String) async {
        let ok = await perform("Rebase", ["rebase", name])
        if !ok, !status.conflicted.isEmpty { selection = .workingCopy }
    }

    // MARK: Commits

    func cherryPick(_ sha: String) async {
        await perform("Cherry-pick", ["cherry-pick", sha])
    }

    func revert(_ sha: String) async {
        await perform("Revert", ["revert", "--no-edit", sha])
    }

    func reset(to sha: String, mode: ResetMode) {
        let branch = currentBranch ?? "HEAD"
        let short = String(sha.prefix(7))
        if mode == .hard {
            confirmation = Confirmation(
                title: String(localized: "Hard reset \(branch) to \(short)?"),
                message: String(localized: "All uncommitted changes are lost, and commits after \(short) leave the branch. Edit > Undo can move the branch back, but not restore uncommitted changes."),
                confirmTitle: "Reset"
            ) { [weak self] in await self?.performUndoable(.reset(.hard), "Reset", ["reset", "--hard", sha]) }
        } else {
            Task { await performUndoable(.reset(mode), "Reset", ["reset", "--\(mode.rawValue)", sha]) }
        }
    }

    func createTag(_ name: String, at sha: String, message: String) async {
        if message.isEmpty {
            await perform("Create tag", ["tag", name, sha])
        } else {
            await perform("Create tag", ["tag", "-a", name, "-m", message, sha])
        }
    }

    func deleteTag(_ name: String) {
        confirmation = Confirmation(title: String(localized: "Delete tag \(name)?"), message: "Only deletes the local tag.",
                                    confirmTitle: "Delete") { [weak self] in
            await self?.perform("Delete tag", ["tag", "-d", name])
        }
    }

    func pushTag(_ name: String) async {
        guard let remote = defaultRemote else { return }
        await perform("Push tag", ["push", remote, "refs/tags/\(name)"])
    }

    // MARK: Working copy

    @discardableResult
    func stage(_ changes: [FileChange]) async -> Bool {
        let paths = changes.map(\.path)
        guard !paths.isEmpty else { return false }
        return await perform("Stage", ["add", "--"] + paths)
    }

    func stageAll() async {
        await perform("Stage all", ["add", "-A"])
    }

    @discardableResult
    func unstage(_ changes: [FileChange]) async -> Bool {
        var paths = changes.map(\.path)
        paths += changes.compactMap(\.oldPath)
        guard !paths.isEmpty else { return false }
        if headSHA == nil {
            return await perform("Unstage", ["rm", "--cached", "-r", "-q", "--"] + paths)
        } else {
            return await perform("Unstage", ["restore", "--staged", "--"] + paths)
        }
    }

    func unstageAll() async {
        if headSHA == nil {
            await perform("Unstage all", ["rm", "--cached", "-r", "-q", "."])
        } else {
            await perform("Unstage all", ["reset", "-q"])
        }
    }

    func discard(_ changes: [FileChange]) {
        guard !changes.isEmpty else { return }
        let names = changes.count == 1 ? changes[0].path : "\(changes.count) files"
        confirmation = Confirmation(
            title: String(localized: "Discard changes to \(names)?"),
            message: "This can't be undone.",
            confirmTitle: "Discard"
        ) { [weak self] in
            guard let self else { return }
            let untracked = changes.filter { $0.area == .untracked }.map(\.path)
            let tracked = changes.filter { $0.area != .untracked && $0.area != .conflicted }.map(\.path)
            if !tracked.isEmpty { await perform("Discard", ["restore", "--"] + tracked) }
            if !untracked.isEmpty { await perform("Discard", ["clean", "-fdq", "--"] + untracked) }
        }
    }

    func commit(message: String, amend: Bool) async -> Bool {
        var args = ["commit"]
        if amend { args.append("--amend") }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append("--no-edit")
        } else {
            args += ["-m", message]
        }
        // A commit that concludes a merge or cherry-pick isn't offered for undo:
        // a soft reset would silently drop the operation's state.
        if operation != nil { return await perform(amend ? "Amend" : "Commit", args) }
        return await performUndoable(amend ? .amend : .commit, amend ? "Amend" : "Commit", args)
    }

    /// Resolves a conflict with one whole side. `mine` is the user's own
    /// version: git's --ours for merge / cherry-pick / revert, but --theirs
    /// during a rebase (there --ours is the branch being rebased onto).
    func resolve(_ change: FileChange, mine: Bool) async {
        let side = (operation == .rebase) == mine ? "theirs" : "ours"
        guard await perform("Resolve", ["checkout", "--\(side)", "--", change.path]) else { return }
        await perform("Resolve", ["add", "--", change.path])
    }

    /// Stages, unstages or discards one hunk (a patch from DiffDocument.patch(forHunk:)).
    @discardableResult
    func applyHunk(_ patch: Data, _ action: HunkAction, zeroContext: Bool) async -> Bool {
        // --whitespace=nowarn also overrides apply.whitespace=fix, which would
        // otherwise rewrite the staged lines.
        var args = ["apply", "--whitespace=nowarn"]
        switch action {
        case .stage: args += ["--cached"]
        case .unstage: args += ["--cached", "--reverse"]
        case .discard: args += ["--reverse"]
        }
        if zeroContext { args.append("--unidiff-zero") }   // diff.context=0
        args.append("-")
        guard beginBusy(action.title) else { return false }
        defer { endBusy(action.title) }
        do {
            try await git.run(args, in: root, logged: true, input: patch)
            await refresh()
            return true
        } catch {
            await refresh()
            alert = AlertItem(title: String(localized: "\(action.title) failed"), message: error.localizedDescription)
            return false
        }
    }

    /// Clones `url` into `dest` (a folder that doesn't exist yet). Used before a repo window exists.
    /// `picked` is the account whose repository list it came from; the new
    /// repository keeps using that account.
    static func clone(_ url: String, into dest: String, picked: HostAccount? = nil) async throws {
        let parent = URL(fileURLWithPath: dest).deletingLastPathComponent()
        let all = Credentials.shared.all
        var args = ["clone"]
        if let picked, all.filter({ $0.host == picked.host }).count > 1 {
            args += ["-c", "\(RepoAccounts.configKey(host: picked.host))=\(picked.username)"]
        }
        args += ["--end-of-options", url, dest]
        try await GitRunner.shared.run(args, in: parent, logged: true,
                                       account: picked ?? RepoAccounts.account(forURL: url, among: all))
    }

    /// Makes this repository use `account` on its host from now on.
    func useAccount(_ account: HostAccount) async {
        let args = ["config", "--local", RepoAccounts.configKey(host: account.host), account.username]
        do {
            // Not `perform`: nothing in the repo moves, so Undo stays available.
            try await git.run(args, in: root, logged: true)
            autoFetcher.note(fetched: false, succeeded: true)   // a sign-in pause was about the old account
            await updateHostStatus(force: true)
        } catch {
            let label = L("Switch account")
            alert = AlertItem(title: String(localized: "\(label) failed"), message: error.localizedDescription)
        }
    }

    // MARK: Merge / rebase in progress

    func continueOperation() async {
        switch operation {
        case .merge: await perform("Continue merge", ["commit", "--no-edit"])
        case .rebase: await perform("Continue rebase", ["rebase", "--continue"])
        case .cherryPick: await perform("Continue cherry-pick", ["cherry-pick", "--continue"])
        case .revert: await perform("Continue revert", ["revert", "--continue"])
        case nil: break
        }
    }

    func abortOperation() async {
        switch operation {
        case .merge: await perform("Abort merge", ["merge", "--abort"])
        case .rebase: await perform("Abort rebase", ["rebase", "--abort"])
        case .cherryPick: await perform("Abort cherry-pick", ["cherry-pick", "--abort"])
        case .revert: await perform("Abort revert", ["revert", "--abort"])
        case nil: break
        }
    }

    func skipRebaseCommit() async {
        await perform("Skip commit", ["rebase", "--skip"])
    }

    // MARK: Stash

    func stash(message: String) async {
        var args = ["stash", "push", "--include-untracked"]
        if !message.isEmpty { args += ["-m", message] }
        await perform("Stash", args)
    }

    func popStash(_ stash: Stash? = nil) async {
        await perform("Pop stash", ["stash", "pop"] + (stash.map { [$0.selector] } ?? []))
    }

    func applyStash(_ stash: Stash) async {
        await perform("Apply stash", ["stash", "apply", stash.selector])
    }

    func dropStash(_ stash: Stash) {
        confirmation = Confirmation(title: String(localized: "Delete \(stash.selector)?"), message: stash.message,
                                    confirmTitle: "Delete") { [weak self] in
            await self?.perform("Drop stash", ["stash", "drop", stash.selector])
        }
    }

    // MARK: Worktrees

    func addWorktree(path: String, newBranch: String?, base: String) async -> Bool {
        if let newBranch {
            // Like createBranch: a new branch started from a remote branch must
            // not track it (a bare `git push` would go to that branch), unless
            // it's the same branch checked out locally.
            let sameRemoteBranch = refs.contains { $0.kind == .remoteBranch && $0.name == base && split($0)?.branch == newBranch }
            return await perform("Add worktree", ["worktree", "add"] + (sameRemoteBranch ? ["--track"] : ["--no-track"])
                                    + ["-b", newBranch, "--end-of-options", path, base])
        }
        return await perform("Add worktree", ["worktree", "add", "--end-of-options", path, base])
    }

    /// Asks, then removes the worktree's folder (the branch stays). The main
    /// worktree is never removed. For the worktree this window shows, `leave`
    /// gets the main worktree's path first and must switch the window there.
    /// Runs in the background: the row shows "Removing…" and the app stays usable.
    func removeWorktree(_ wt: Worktree, leave: ((String) -> Void)? = nil) {
        guard !wt.isMain, !WorktreeRemovals.shared.contains(wt.path) else { return }
        let isCurrent = sidebarIsCurrent(wt)
        guard !isCurrent || (leave != nil && canLeaveForMainWorktree) else { return }
        let main = mainWorktreePath
        let dirty = (worktreeInfo[wt.path]?.changes ?? 0) > 0
        var message = dirty
            ? String(localized: "It has uncommitted changes. They will be lost. The branch \(wt.branch ?? "") stays.")
            : String(localized: "Deletes the folder \(wt.path). The branch \(wt.branch ?? "") stays.")
        if isCurrent { message += "\n\n" + String(localized: "This tab then shows the main worktree.") }
        let args = ["worktree", "remove"] + (dirty ? ["--force"] : []) + [wt.path]
        confirmation = Confirmation(
            title: String(localized: "Remove worktree \(wt.displayName)?"),
            message: message,
            confirmTitle: "Remove"
        ) { [weak self] in
            guard let self else { return }
            // Never in the folder being deleted: run it from the main worktree.
            let dir = main.map { URL(fileURLWithPath: $0) } ?? self.root
            let leaveFirst = isCurrent ? leave.flatMap { leave in main.map { main in { leave(main) } } } : nil
            Task { await self.removeInBackground(wt, args: args, in: dir, leaveFirst: leaveFirst) }
        }
    }

    /// The window can move to the main worktree when its own one is removed
    /// (not when the main one is a bare repository, which has no files to show).
    var canLeaveForMainWorktree: Bool {
        guard let main = worktrees.first(where: \.isMain) else { return false }
        return !main.isBare
    }

    /// Removes the worktree without taking `busy`, so pull, commit and the rest
    /// keep working meanwhile. `leaveFirst` moves this window off the worktree
    /// before its folder goes away.
    private func removeInBackground(_ wt: Worktree, args: [String], in dir: URL, leaveFirst: (() -> Void)?) async {
        let removals = WorktreeRemovals.shared
        guard removals.begin(wt.path) else { return }
        defer { removals.end(wt.path) }
        if let leaveFirst {
            lastUndo = nil
            leaveFirst()
        }
        do {
            try await git.run(args, in: dir, logged: true)
            if leaveFirst == nil { await refresh() }
        } catch {
            let title = String(localized: "Remove worktree failed")
            if leaveFirst == nil {
                await refresh()
                alert = AlertItem(title: title, message: error.localizedDescription)
            } else {
                WorktreeRemovals.reportFailure(title, error.localizedDescription)
            }
        }
    }

    func pruneWorktrees() async {
        await perform("Prune worktrees", ["worktree", "prune"])
    }

    /// Suggested folder for a new worktree: a sibling of the main checkout, `<repo>-<branch>`.
    func suggestedWorktreePath(branch: String) -> String {
        WorktreePath.suggest(main: mainWorktreePath ?? root.path, branch: branch)
    }
}
