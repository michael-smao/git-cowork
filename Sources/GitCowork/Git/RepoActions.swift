import CoworkKit
import Foundation
import GitCoworkCore

/// Everything the user can do to a repo. Each action is one or two plain git
/// commands; they all show up in the command log.
extension RepoModel {
    /// Runs a git command that changes the repo, then refreshes. A failure
    /// is shown in plain words with next steps (RepoProblems), unless `quiet`
    /// (a sheet shows `lastProblem` inline instead). When the command left
    /// conflicts to resolve, Changes opens instead: its banner says what to do.
    @discardableResult
    func perform(_ label: String, _ args: [String], okCodes: Set<Int32> = [0], quiet: Bool = false) async -> Bool {
        await waitForAutoFetch()
        await waitUntilIdle()
        guard beginBusy(label) else { return false }
        defer { endBusy(label) }
        if !UndoRecord.survives(args) { lastUndo = nil }
        do {
            try await git.run(args, in: root, logged: true, okCodes: okCodes)
            await refresh()
            if args.contains("--autostash"), !status.conflicted.isEmpty { showAutostashConflict() }
            return true
        } catch {
            await refresh()
            report(error, label: label, args: args, quiet: quiet)
            return false
        }
    }

    /// Shows a failed command as a GitProblem, or opens Changes when it
    /// stopped with conflicts (the operation banner explains the rest).
    func report(_ error: Error, label: String, args: [String], quiet: Bool = false) {
        let problem = problem(for: error, label: label, args: args)
        lastProblem = problem
        if operation != nil || !status.conflicted.isEmpty {
            openDiff = nil
            centerMode = .history
            selection = .workingCopy
            return
        }
        if !quiet { self.problem = problem }
    }

    /// `--autostash` put the changes back with conflicts: git still counts
    /// that as success and keeps them in a stash. Changes says so (like a
    /// stash popped with conflicts) instead of nothing.
    private func showAutostashConflict() {
        stashConflict = stashes.first
        openDiff = nil
        centerMode = .history
        selection = .workingCopy
    }

    /// Waits for the action that's running to finish, so a second click runs
    /// next instead of being refused.
    func waitUntilIdle() async {
        var waited = 0
        while busy != nil, waited < 6000 {   // 10 minutes at most
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
    }

    /// One git action at a time. Claims `busy` for `label`; if another action
    /// is still running after waiting, says why nothing happened.
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

    /// Pull ▾ variants run as chosen. The plain Pull fast-forwards when it can
    /// and asks merge or rebase when both sides have new commits, instead of
    /// git's "divergent branches" error. If the user set pull.rebase or pull.ff
    /// in git config, plain `git pull` already follows that choice.
    func pull(_ mode: PullMode = .default) async {
        guard mode == .default, status.upstream != nil, await !hasPullPreference() else {
            let ok = await perform("Pull", mode.args)
            noteRemoteAction(fetched: true, succeeded: ok)
            return
        }
        let fetched = await perform("Pull", ["fetch"])
        noteRemoteAction(fetched: true, succeeded: fetched)
        guard fetched else { return }
        await catchUp(with: "@{upstream}", named: status.upstream ?? "upstream")
    }

    private func hasPullPreference() async -> Bool {
        for key in CatchUp.pullPreferenceKeys {
            if let value = await git.tryRun(["config", "--get", key], in: root),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        return false
    }

    /// Brings the checked-out branch up to `target` (a remote branch):
    /// fast-forward when only `target` moved, nothing when it has no new
    /// commits, and a question when both moved. Uncommitted changes are
    /// stashed around it and put back (`--autostash`).
    func catchUp(with target: String, named name: String) async {
        guard let out = await git.tryRun(["rev-list", "--left-right", "--count", "HEAD...\(target)"], in: root),
              let plan = CatchUp(revListCounts: out) else {
            // Typically the upstream branch was deleted on the server (its pull request merged).
            alert = AlertItem(title: String(localized: "\(name) doesn't exist anymore"),
                              message: String(localized: "It was probably deleted on the server, for example after its pull request was merged. Nothing was pulled. Push to create it again, or switch to another branch."))
            return
        }
        let branch = currentBranch ?? "HEAD"
        switch plan {
        case .upToDate, .aheadOnly:
            return
        case .fastForward:
            await perform("Pull", ["merge", "--ff-only", "--autostash", target])
        case .diverged(let ahead, let behind):
            confirmation = Confirmation(
                title: String(localized: "\(branch) and \(name) both have new commits"),
                message: String(localized: "\(branch) has \(ahead) commits that \(name) doesn't, and \(name) has \(behind) new ones. Merge joins them with a merge commit. Rebase puts your \(ahead) commits on top of \(name). Nothing is lost either way."),
                confirmTitle: "Merge",
                destructive: false,
                action: { [weak self] in await self?.perform("Pull", ["merge", "--no-edit", "--autostash", target]) },
                alternativeTitle: L("Rebase"),
                alternative: { [weak self] in await self?.perform("Pull", ["rebase", "--autostash", target]) }
            )
        }
    }

    /// Double-click on a remote branch: check out its local branch (a new
    /// tracking one if there is none) and bring it up to date with the remote,
    /// asking first when both have new commits.
    func checkoutAndPull(_ remote: Ref) async {
        guard remote.kind == .remoteBranch, let (remoteName, branch) = split(remote),
              localBranch(named: branch) != nil else {
            await checkout(remote)
            return
        }
        if currentBranch != branch {
            await checkout(remote)
            guard currentBranch == branch else { return }   // refused or failed: it said why
        }
        // Fresh remote state first; offline, the last fetch still works.
        _ = await git.tryRun(["fetch", "--end-of-options", remoteName, branch], in: root)
        await refresh()
        await catchUp(with: remote.name, named: remote.name)
    }

    /// A branch without an upstream asks where to push first (like
    /// GitKraken); without any remote, it asks to add one.
    func push(force: Bool = false) async {
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        if status.upstream == nil {
            guard let branch = currentBranch else {
                problem = GitProblem(title: L("Not on a branch"), message: L("You're on a commit, not a branch, so there's nothing to push. Create a branch here first."))
                return
            }
            sheet = remoteNames.isEmpty ? .addRemote(thenPush: branch) : .pushTarget(branch: branch)
            return
        }
        // git refuses a plain push when the upstream has another name (push.default
        // simple). Pushing there could even be main: ask where it should go.
        if let upstream = status.upstream, let branch = currentBranch,
           let target = RefName.splitRemote(upstream, remotes: remoteNames), target.branch != branch {
            askPushTarget(branch: branch, upstream: upstream, remote: target.remote, upstreamBranch: target.branch, force: force)
            return
        }
        if await perform(force ? "Force push" : "Push", args) {
            noteRemoteAction(fetched: false, succeeded: true)
        }
    }

    /// The branch follows a remote branch with another name: push there, or
    /// to a new remote branch of the same name that it follows from now on.
    private func askPushTarget(branch: String, upstream: String, remote: String, upstreamBranch: String, force: Bool) {
        confirmation = Confirmation(
            title: String(localized: "Where should \(branch) go?"),
            message: String(localized: "\(branch) follows \(upstream), a branch with another name. Push your commits there, or to a new branch \(remote)/\(branch) that it follows from now on."),
            confirmTitle: String(localized: "Push to \(upstream)"),
            destructive: false,
            action: { [weak self] in
                guard let self else { return }
                var args = ["push"]
                if force { args.append("--force-with-lease") }
                args += ["--end-of-options", remote, "refs/heads/\(branch):refs/heads/\(upstreamBranch)"]
                if await perform(force ? "Force push" : "Push", args) { noteRemoteAction(fetched: false, succeeded: true) }
            },
            alternativeTitle: String(localized: "Push as \(remote)/\(branch)"),
            alternative: { [weak self] in await self?.push(branch: branch, to: remote, as: branch) }
        )
    }

    /// Pushes `branch` to `remoteBranch` on `remote` and tracks it from now on.
    @discardableResult
    func push(branch: String, to remote: String, as remoteBranch: String, quiet: Bool = false) async -> Bool {
        let ok = await perform("Push", ["push", "-u", "--end-of-options", remote, "refs/heads/\(branch):refs/heads/\(remoteBranch)"], quiet: quiet)
        if ok { noteRemoteAction(fetched: false, succeeded: true) }
        return ok
    }

    /// Adds a remote: the first one, or another (a fork, the repository it was forked from).
    @discardableResult
    func addRemote(name: String, url: String, quiet: Bool = false) async -> Bool {
        await perform("Add remote", ["remote", "add", "--", name, url], quiet: quiet)
    }

    /// Fetches one remote (the toolbar's Fetch gets all of them).
    func fetch(remote name: String) async {
        let ok = await perform("Fetch", ["fetch", "--prune", "--", name])
        noteRemoteAction(fetched: false, succeeded: ok)
    }

    /// Gives a remote a new name, a new URL, or both.
    @discardableResult
    func editRemote(_ old: String, name: String, url: String, quiet: Bool = false) async -> Bool {
        if name != old {
            guard await perform("Rename remote", ["remote", "rename", "--", old, name], quiet: quiet) else { return false }
            // Tasks keep syncing with the same remote under its new name.
            if await git.tryLine(["config", "--get", CoworkRemote.configKey], in: root) == old {
                _ = try? await git.run(CoworkRemote.rememberArgs(name), in: root, logged: true)
            }
            cowork.remote = await resolveCoworkRemote()
        }
        if url != remotes.first(where: { $0.name == name })?.url {
            guard await perform("Change remote URL", ["remote", "set-url", "--", name, url], quiet: quiet) else { return false }
        }
        return true
    }

    /// Always asks: the remote's branches disappear from the sidebar and the graph.
    func removeRemote(_ name: String) {
        let tracking = localBranches.filter { $0.upstream.flatMap { remoteBranch(fullName: $0) }.flatMap(split)?.remote == name }.count
        var message = String(localized: "Its branches disappear from this repository. Nothing changes on the server, and your local branches and commits stay.")
        if tracking == 1 {
            message += " " + L("1 local branch pushes to and pulls from it and will have no remote branch afterwards.")
        } else if tracking > 1 {
            message += " " + String(localized: "\(tracking) local branches push to and pull from it and will have no remote branch afterwards.")
        }
        confirmation = Confirmation(title: String(localized: "Remove remote \(name)?"), message: message,
                                    confirmTitle: "Remove") { [weak self] in
            guard let self, await perform("Remove remote", ["remote", "remove", "--", name]) else { return }
            cowork.remote = await resolveCoworkRemote()
        }
    }

    /// Always asks: a force push replaces the branch on the server.
    func confirmForcePush() {
        let branch = currentBranch ?? "HEAD"
        let upstream = status.upstream ?? String(localized: "the remote branch")
        confirmation = Confirmation(
            title: String(localized: "Force push \(branch)?"),
            message: String(localized: "This replaces \(upstream) on the server with your \(branch). Commits there that you don't have are removed for everyone. --force-with-lease refuses if somebody pushed since your last fetch."),
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

    /// When `branch` is checked out in another worktree, goes there instead:
    /// focuses its tab, else switches this window to it. Changes here stay in
    /// this worktree. Without a window to switch (`openWorktree` is nil), it
    /// alerts like `refuseIfCheckedOutElsewhere`. Returns true when the branch
    /// is elsewhere, so the caller stops.
    func openWorktreeIfCheckedOutElsewhere(_ branch: String) -> Bool {
        guard let wt = worktree(holding: branch) else { return false }
        guard let openWorktree else { return refuseIfCheckedOutElsewhere(branch) }
        openWorktree(wt.path)
        return true
    }

    /// Checks out a branch or tag. A branch another worktree has checked out
    /// (also as the local branch of a remote one) opens that worktree instead.
    func checkout(_ ref: Ref) async {
        let local = split(ref)?.branch ?? ref.name
        if ref.kind != .tag, openWorktreeIfCheckedOutElsewhere(local) { return }
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
    func createBranch(_ name: String, from start: String, checkout: Bool, quiet: Bool = false) async -> Bool {
        if checkout {
            return await perform("Create branch", ["switch", "--no-track", "-c", name, "--end-of-options", start], quiet: quiet)
        } else {
            return await perform("Create branch", ["branch", "--no-track", "--end-of-options", name, start], quiet: quiet)
        }
    }

    /// The last failure in one paragraph, for sheets that show it inline.
    var lastProblemText: String? {
        lastProblem.map { "\($0.title)\n\($0.message)" }
    }

    /// Pushes a branch that may not be checked out here, or is checked out in
    /// another worktree. A branch without an upstream gets one.
    /// `askWhere: false` (sheets that push on their own) pushes a branch
    /// without upstream to the default remote under the same name.
    @discardableResult
    func push(branch: String, quiet: Bool = false, askWhere: Bool = true) async -> Bool {
        let upstream = localBranch(named: branch)?.upstream
        if upstream == nil, askWhere {
            sheet = remoteNames.isEmpty ? .addRemote(thenPush: branch) : .pushTarget(branch: branch)
            return false
        }
        guard let args = BranchLookup.pushArguments(branch: branch, upstream: upstream,
                                                    remotes: remoteNames, fallbackRemote: defaultRemote) else {
            sheet = .addRemote(thenPush: branch)
            return false
        }
        let pushed = await perform("Push", args, quiet: quiet)
        if pushed { noteRemoteAction(fetched: false, succeeded: true) }
        return pushed
    }

    @discardableResult
    func renameBranch(_ old: String, to new: String, quiet: Bool = false) async -> Bool {
        await perform("Rename branch", ["branch", "-m", old, new], quiet: quiet)
    }

    func deleteBranch(_ ref: Ref) {
        if let s = split(ref) {
            let remote = s.remote, branch = s.branch
            confirmation = Confirmation(
                title: String(localized: "Delete \(ref.name) on \(remote)?"),
                message: "This deletes the branch on the server for everyone.",
                confirmTitle: "Delete Remote Branch"
            ) { [weak self] in await self?.deleteRemoteBranch(branch, on: remote) }
            return
        }
        Task { await confirmDeleteLocalBranch(ref) }
    }

    /// Always asks first. Says how many commits exist only on the branch, and
    /// offers deleting its remote branch too.
    private func confirmDeleteLocalBranch(_ ref: Ref) async {
        let only = await git.tryLine(["rev-list", "--count", "refs/heads/\(ref.name)", "--not",
                                      "--exclude=\(ref.name)", "--branches", "--remotes"], in: root)
            .flatMap(Int.init) ?? 0
        var message = only == 0
            ? L("All its commits are also on other branches, so nothing is lost.")
            : only == 1
                ? L("1 commit exists only on this branch and goes away with it.")
                : String(localized: "\(only) commits exist only on this branch and go away with it.")
        message += " " + L("Edit > Undo brings the branch back until you run another git command.")
        let remote = ref.upstream.flatMap { up in remoteBranch(fullName: up) != nil && !ref.upstreamGone ? up : nil }
        let deleteLocal: () async -> Void = { [weak self] in
            guard let self, await perform("Delete branch", ["branch", "-D", ref.name]) else { return }
            recordDeletedBranch(ref)
        }
        var c = Confirmation(title: String(localized: "Delete \(ref.name)?"), message: message,
                             confirmTitle: "Delete", action: deleteLocal)
        if let remote, let parts = remoteBranch(fullName: remote).flatMap(split) {
            c.alternativeTitle = String(localized: "Delete Here and on \(parts.remote)")
            c.alternative = { [weak self] in
                await deleteLocal()
                await self?.deleteRemoteBranch(parts.branch, on: parts.remote)
            }
        }
        confirmation = c
    }

    /// Deletes a branch on the server. If it's already gone there, cleans up
    /// the stale entry here and says so instead of failing.
    func deleteRemoteBranch(_ branch: String, on remote: String) async {
        let args = ["push", remote, "--delete", "refs/heads/\(branch)"]
        await waitUntilIdle()
        guard beginBusy("Delete remote branch") else { return }
        do {
            try await git.run(args, in: root, logged: true)
            endBusy("Delete remote branch")
            await refresh()
        } catch {
            endBusy("Delete remote branch")
            let raw = (error as? GitError)?.result.stderr ?? ""
            if GitFailure.classify(raw) == .remoteRefMissing {
                _ = try? await git.run(["fetch", "--prune", remote], in: root, logged: true)
                await refresh()
            }
            report(error, label: "Delete remote branch", args: args)
        }
    }

    /// `--autostash`: uncommitted changes are put aside and back, like GitKraken.
    /// Conflicts open Changes (see `report`).
    func merge(_ name: String) async {
        await perform("Merge", ["merge", "--autostash", "--no-edit", name])
    }

    func rebase(onto name: String) async {
        await perform("Rebase", ["rebase", "--autostash", name])
    }

    // MARK: Commits

    /// A merge commit has two parents, so git needs to know which side counts
    /// as "before" (`-m`). Like GitKraken and Fork: the first parent, the
    /// branch that was merged into, which is what you mean almost always.
    func cherryPick(_ sha: String) async {
        guard commit(sha)?.isMerge == true else {
            await perform("Cherry-pick", ["cherry-pick", sha])
            return
        }
        let subject = commit(sha)?.subject ?? String(sha.prefix(7))
        confirmation = Confirmation(
            title: String(localized: "Cherry-pick the merge \(String(sha.prefix(7)))?"),
            message: String(localized: "\(subject)\n\nThis copies everything the merge brought in onto \(currentBranch ?? "HEAD") as one new commit."),
            confirmTitle: "Cherry-pick", destructive: false
        ) { [weak self] in await self?.perform("Cherry-pick", ["cherry-pick", "-m", "1", sha]) }
    }

    func revert(_ sha: String) async {
        guard commit(sha)?.isMerge == true else {
            await perform("Revert", ["revert", "--no-edit", sha])
            return
        }
        let subject = commit(sha)?.subject ?? String(sha.prefix(7))
        confirmation = Confirmation(
            title: String(localized: "Revert the merge \(String(sha.prefix(7)))?"),
            message: String(localized: "\(subject)\n\nThis adds a commit that takes out everything the merge brought in. Merging the same branch again later won't bring those changes back; revert this revert for that."),
            confirmTitle: "Revert", destructive: false
        ) { [weak self] in await self?.perform("Revert", ["revert", "--no-edit", "-m", "1", sha]) }
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

    @discardableResult
    func createTag(_ name: String, at sha: String, message: String, quiet: Bool = false) async -> Bool {
        if message.isEmpty {
            return await perform("Create tag", ["tag", name, sha], quiet: quiet)
        } else {
            return await perform("Create tag", ["tag", "-a", name, "-m", message, sha], quiet: quiet)
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

    /// Discards working-copy changes (staged ones stay, like `git restore`).
    /// A snapshot of the files is saved first, so Edit > Undo brings them back.
    func discard(_ changes: [FileChange]) {
        guard changes.contains(where: { $0.area != .conflicted }) else { return }
        let names = changes.count == 1 ? changes[0].path : String(localized: "\(changes.count) files")
        confirmation = Confirmation(
            title: String(localized: "Discard changes to \(names)?"),
            message: L("Edit > Undo brings them back until you edit them again, commit or switch branches."),
            confirmTitle: "Discard"
        ) { [weak self] in
            guard let self else { return }
            let untracked = changes.filter { $0.area == .untracked }.map(\.path)
            let tracked = changes.filter { $0.area != .untracked && $0.area != .conflicted }.map(\.path)
            let head = HeadState(sha: status.headOID, branch: status.branch)
            let snapshot = await snapshotWorkingCopy(tracked + untracked)
            var ok = true
            if !tracked.isEmpty { ok = await perform("Discard", ["restore", "--"] + tracked) && ok }
            if !untracked.isEmpty { ok = await perform("Discard", ["clean", "-fdq", "--"] + untracked) && ok }
            if ok, let snapshot {
                lastUndo = UndoRecord(action: .discard(snapshot: snapshot, paths: tracked + untracked), before: head, after: head)
            }
        }
    }

    /// Saves the working-copy version of `paths` in a commit no branch points
    /// at, without touching the index or the files (a separate index file).
    /// Nil if that fails; the discard then can't be undone.
    private func snapshotWorkingCopy(_ paths: [String]) async -> String? {
        guard !paths.isEmpty, let gitDir else { return nil }
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("git-cowork-\(UUID().uuidString).index")
        defer { try? FileManager.default.removeItem(at: index) }
        let real = gitDir.appendingPathComponent("index")
        if FileManager.default.fileExists(atPath: real.path) {
            guard (try? FileManager.default.copyItem(at: real, to: index)) != nil else { return nil }
        }
        // A fixed author: the snapshot is never shown, and git may not know the user's name yet.
        let env = ["GIT_INDEX_FILE": index.path,
                   "GIT_AUTHOR_NAME": "git-cowork", "GIT_AUTHOR_EMAIL": "git-cowork@localhost",
                   "GIT_COMMITTER_NAME": "git-cowork", "GIT_COMMITTER_EMAIL": "git-cowork@localhost"]
        guard await git.execute(["add", "-A", "--"] + paths, in: root, env: env).exitCode == 0 else { return nil }
        let tree = await git.execute(["write-tree"], in: root, env: env)
        let treeSHA = tree.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tree.exitCode == 0, !treeSHA.isEmpty else { return nil }
        let parent = status.headOID.map { ["-p", $0] } ?? []
        let commit = await git.execute(["commit-tree", treeSHA] + parent + ["-m", "git-cowork: discarded changes"], in: root, env: env)
        let sha = commit.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.exitCode == 0 && !sha.isEmpty ? sha : nil
    }

    /// Adds `patterns` to this worktree's `.gitignore` (created if there is
    /// none). Not a git command: only that file changes, and it then shows
    /// under Changes like any other edit, where it can be reviewed or discarded.
    func ignore(_ patterns: [String]) async {
        let file = root.appendingPathComponent(".gitignore")
        let old = (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let new = GitIgnore.adding(patterns, to: old)
        // Only what was added is written, at the end: the bytes already there
        // (whatever their encoding) and a symlinked file stay as they are.
        let added = Data(new.utf8.dropFirst(old.utf8.count))
        guard !added.isEmpty else { return }
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data().write(to: file)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: added)
        } catch {
            alert = AlertItem(title: L("Couldn't change .gitignore"), message: error.localizedDescription)
            return
        }
        await refresh()
    }

    func commit(message: String, amend: Bool) async -> Bool {
        // No name or email yet: ask for them once, then commit (git would only print instructions).
        if await git.tryRun(["var", "GIT_AUTHOR_IDENT"], in: root) == nil {
            afterIdentity = { [weak self] in
                guard let self, await commit(message: message, amend: amend) else { return }
                draftSummary = ""
                draftDetails = ""
            }
            sheet = .identity
            return false
        }
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

    /// Nothing staged yet: stage everything, then commit.
    func stageAllAndCommit(message: String) async -> Bool {
        guard await perform("Stage all", ["add", "-A"]) else { return false }
        return await commit(message: message, amend: false)
    }

    /// A repository without commits (e.g. a fresh clone of an empty one):
    /// adds a README if there's none and makes the first commit.
    func makeInitialCommit() async {
        let readme = root.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try? "# \(name)\n".write(to: readme, atomically: true, encoding: .utf8)
        }
        guard await perform("Stage", ["add", "--", "README.md"]) else { return }
        _ = await commit(message: "Initial commit", amend: false)
    }

    /// Saves the name and email git signs commits with, for all repositories
    /// (`--global`) or just this one, then runs what was waiting for them.
    func saveIdentity(name: String, email: String, global: Bool, quiet: Bool = true) async -> Bool {
        let scope = global ? "--global" : "--local"
        guard await perform("Set name", ["config", scope, "user.name", name], quiet: quiet),
              await perform("Set email", ["config", scope, "user.email", email], quiet: quiet) else { return false }
        let next = afterIdentity
        afterIdentity = nil
        await next?()
        return true
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
        await waitUntilIdle()
        guard beginBusy(action.title) else { return false }
        defer { endBusy(action.title) }
        do {
            try await git.run(args, in: root, logged: true, input: patch)
            await refresh()
            return true
        } catch {
            await refresh()
            report(error, label: action.title, args: args)
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
            report(error, label: "Switch account", args: args)
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

    @discardableResult
    func stash(message: String, quiet: Bool = false) async -> Bool {
        var args = ["stash", "push", "--include-untracked"]
        if !message.isEmpty { args += ["-m", message] }
        return await perform("Stash", args, quiet: quiet)
    }

    /// With conflicts git keeps the stash; Changes then says so and offers to drop it.
    func popStash(_ stash: Stash? = nil) async {
        let target = stash ?? stashes.first
        let ok = await perform("Pop stash", ["stash", "pop"] + (stash.map { [$0.selector] } ?? []))
        if !ok, !status.conflicted.isEmpty { stashConflict = target }
    }

    func applyStash(_ stash: Stash) async {
        let ok = await perform("Apply stash", ["stash", "apply", stash.selector])
        if !ok, !status.conflicted.isEmpty { stashConflict = stash }
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
