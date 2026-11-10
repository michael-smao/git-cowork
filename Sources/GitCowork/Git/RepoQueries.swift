import Foundation
import GitCoworkCore

/// Read-only questions about the repo that several screens ask. Views call
/// these instead of building git commands themselves.
extension RepoModel {
    // MARK: Branch lookup

    func localBranch(named name: String) -> Ref? {
        localBranches.first { $0.name == name }
    }

    /// Remote-tracking ref for a branch name: on the default remote, else on any remote.
    func remoteBranch(named name: String) -> Ref? {
        BranchLookup.remote(named: name, in: refs, preferred: defaultRemote ?? "origin", remotes: remoteNames)
    }

    /// Remote-tracking ref by its full short name, like "origin/main"
    /// (`remoteBranch(named:)` takes a branch name without the remote).
    func remoteBranch(fullName: String) -> Ref? {
        remoteBranches.first { $0.name == fullName }
    }

    /// Local branch if there is one, else the remote-tracking one.
    func branch(named name: String) -> Ref? {
        localBranch(named: name) ?? remoteBranch(named: name)
    }

    /// Remote and branch name of a remote-tracking ref, by the repo's remote names.
    func split(_ ref: Ref) -> (remote: String, branch: String)? {
        ref.split(remotes: remoteNames)
    }

    /// The branch new work starts from and reviews compare against: the
    /// remote's default branch ("origin/main") if fetched, else a local
    /// main/master. `name` is the plain name ("main") for PR links and pickers.
    func baseBranch() -> BaseBranch? {
        let remote = defaultRemote
        return BaseBranch.resolve(remote: remote, remoteHEAD: defaultBranch(remote: remote),
                                  remoteBranches: remoteBranches.map(\.name), localBranches: localBranches.map(\.name))
    }

    /// Plain name of the base branch for review requests: "main" when the repo gives no hint.
    var baseBranchName: String { baseBranch()?.name ?? BaseBranch.fallbackName }

    // MARK: Commits

    /// Full sha of a revision, or nil if it doesn't exist.
    func sha(_ rev: String) async -> String? {
        await git.tryLine(["rev-parse", "--verify", "-q", rev + "^{commit}"], in: root)
    }

    func isAncestor(_ a: String, of b: String) async -> Bool {
        await git.execute(["merge-base", "--is-ancestor", a, b], in: root).exitCode == 0
    }

    /// Commits on HEAD that aren't on `base`.
    func commitsAhead(of base: String) async -> Int? {
        Int(await git.tryLine(["rev-list", "--count", "\(base)..HEAD"], in: root) ?? "")
    }

    // MARK: Review changes

    /// Files changed on `branch` since it left `base`, plus a stand-in commit
    /// (the tip, with the merge base as its parent) so the diff viewer can show them.
    /// Both names come from shared review data, so they're checked first.
    func branchChanges(branch: String, base: String) async -> BranchChanges {
        var result = BranchChanges(loaded: true)
        for name in [branch, base] where !RefName.isValid(name) {
            result.error = "\(name) isn't a valid branch name."
            return result
        }
        guard let tip = await resolvedTip(branch) else {
            result.error = "Branch \(branch) isn't here yet. Fetch to get it."
            return result
        }
        guard let baseTip = await resolvedTip(base) else {
            result.error = "Base branch \(base) not found."
            return result
        }
        guard let mb = await git.tryLine(["merge-base", baseTip, tip], in: root) else {
            result.error = "\(branch) and \(base) have no common history."
            return result
        }
        result.files = Parsers.parseNameStatus(await git.tryRun(["diff", "--name-status", "-z", "-M", mb, tip], in: root) ?? "")
        if let d = await commitDetail(tip) {
            result.detail = CommitDetail(
                id: d.id, parents: [mb], authorName: d.authorName, authorEmail: d.authorEmail, authorDate: d.authorDate,
                committerName: d.committerName, committerEmail: d.committerEmail, committerDate: d.committerDate,
                message: String(localized: "\(branch) → \(base)\n\nAll changes on the branch since its merge base \(String(mb.prefix(7)))."))
        }
        return result
    }

    // MARK: Stash contents

    /// What `stash` holds: its changes to tracked files and the untracked
    /// files saved with it. Nil when its commit can't be read.
    func stashContents(_ stash: Stash) async -> StashContents? {
        guard let d = await commitDetail(stash.sha), let parts = StashParts(parents: d.parents) else { return nil }
        func standIn(_ id: String, parents: [String]) -> CommitDetail {
            CommitDetail(id: id, parents: parents, authorName: d.authorName, authorEmail: d.authorEmail, authorDate: d.authorDate,
                         committerName: d.committerName, committerEmail: d.committerEmail, committerDate: d.committerDate,
                         message: d.message)
        }
        let changes = standIn(d.id, parents: [parts.base])
        let changed = await changedFiles(changes)
        var untracked: CommitDetail?
        var added: [FileChange] = []
        if let sha = parts.untracked {
            let commit = standIn(sha, parents: [])
            untracked = commit
            added = await changedFiles(commit)
        }
        return StashContents(changes: changes, untracked: untracked, files: changed + added,
                             untrackedPaths: Set(added.map(\.path)))
    }

    /// The pushed (remote-tracking) branch, unless the local one is at or ahead
    /// of it. A reviewer's stale local checkout must not decide what a review shows.
    private func resolvedTip(_ name: String) async -> String? {
        let local = localBranch(named: name)?.name, remote = remoteBranch(named: name)?.name
        let l = local == nil ? nil : await sha(local!)
        let r = remote == nil ? nil : await sha(remote!)
        switch (l, r) {
        case let (l?, r?): return await isAncestor(r, of: l) ? l : r
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return await sha(name)
        }
    }
}

/// Finds the repository a folder belongs to, before any RepoModel exists.
enum RepoLocator {
    /// Top-level folder of the worktree containing `path`, or nil if it isn't in a git repo.
    static func resolve(_ path: String) async -> String? {
        await GitRunner.shared.tryLine(["rev-parse", "--show-toplevel"], in: URL(fileURLWithPath: path))
    }
}

/// Result of `RepoModel.stashContents`: a stash as two stand-in commits the
/// diff viewer can show.
struct StashContents {
    /// The stash against the commit it was made on.
    let changes: CommitDetail
    /// The commit holding the stashed untracked files. It has no parent, so
    /// every file in it reads as added.
    let untracked: CommitDetail?
    /// Changed files first, then the untracked ones.
    let files: [FileChange]
    let untrackedPaths: Set<String>

    /// The stand-in commit `file` is diffed in.
    func source(of file: FileChange) -> CommitDetail {
        if let untracked, untrackedPaths.contains(file.path) { return untracked }
        return changes
    }

    /// True for one of this stash's two stand-in commits.
    func holds(_ detail: CommitDetail) -> Bool {
        detail.id == changes.id || detail.id == untracked?.id
    }
}

/// Result of `RepoModel.branchChanges`.
struct BranchChanges {
    var loaded = false
    var files: [FileChange] = []
    var detail: CommitDetail?
    var error: String?
}
