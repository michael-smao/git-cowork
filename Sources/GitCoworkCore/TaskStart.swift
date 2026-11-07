import Foundation

/// "Start Task" in the app and `git cowork start`: which branch, and the git
/// command that checks it out here or in a new worktree. Both run exactly
/// these commands.
public enum TaskStart {
    /// The task's linked branch, else one named after it ("CW-a3f9-cache-sessions").
    /// Nil when neither is a valid branch name.
    public static func branchName(for task: CoworkTask) -> String? {
        if let b = task.linkedBranch { return b }
        let made = RefName.branch(for: task)
        return RefName.isValid(made) ? made : nil
    }

    /// Git arguments that put `branch` in place:
    /// - it exists locally: switch to it (or add a worktree on it);
    /// - only `remoteBranch` ("origin/x") exists: a local branch tracking it;
    /// - neither: a new branch from `base` that tracks nothing, so a bare
    ///   `git push` can't go to the base branch.
    /// With `worktreePath` it's `git worktree add`, else `git switch`.
    public static func plan(branch: String, hasLocal: Bool, remoteBranch: String?, base: String,
                            worktreePath: String? = nil) -> [String] {
        if let path = worktreePath {
            if hasLocal { return ["worktree", "add", "--end-of-options", path, branch] }
            if let remoteBranch { return ["worktree", "add", "--track", "-b", branch, "--end-of-options", path, remoteBranch] }
            return ["worktree", "add", "--no-track", "-b", branch, "--end-of-options", path, base]
        }
        if hasLocal { return ["switch", "--end-of-options", branch] }
        if let remoteBranch { return ["switch", "--track", "-c", branch, "--end-of-options", remoteBranch] }
        return ["switch", "--no-track", "-c", branch, "--end-of-options", base]
    }
}

/// Finding branches among a repo's refs.
public enum BranchLookup {
    /// Remote that new work and links default to: the current branch's
    /// upstream remote, else origin, else the first remote.
    public static func defaultRemote(upstream: String?, remotes: [String]) -> String? {
        if let up = upstream, let r = RefName.splitRemote(up, remotes: remotes)?.remote, remotes.contains(r) { return r }
        if remotes.contains("origin") { return "origin" }
        return remotes.first
    }

    /// Remote-tracking ref for a branch name: on `preferred`, else on any remote.
    public static func remote(named name: String, in refs: [Ref], preferred: String?, remotes: [String]) -> Ref? {
        let remoteRefs = refs.filter { $0.kind == .remoteBranch }
        if let preferred, let r = remoteRefs.first(where: { $0.name == "\(preferred)/\(name)" }) { return r }
        return remoteRefs.first { ref in
            guard let s = ref.split(remotes: remotes) else { return false }
            return s.branch == name && s.branch != "HEAD"
        }
    }
}

/// The branch new work starts from and reviews compare against.
public struct BaseBranch: Hashable, Sendable {
    /// What to start from: "origin/main", or a local "main".
    public let ref: String
    /// The plain name ("main"), for review bases and PR links.
    public let name: String

    public init(ref: String, name: String) {
        self.ref = ref
        self.name = name
    }

    /// Review base when the repo gives no hint.
    public static let fallbackName = "main"

    /// The remote's default branch (`remoteHEAD`, from refs/remotes/<remote>/HEAD)
    /// if it's fetched, else that name or main/master as a local branch.
    /// `remoteBranches` are "origin/main" style names.
    public static func resolve(remote: String?, remoteHEAD: String?, remoteBranches: [String],
                               localBranches: [String]) -> BaseBranch? {
        if let remote, let d = remoteHEAD, remoteBranches.contains("\(remote)/\(d)") {
            return BaseBranch(ref: "\(remote)/\(d)", name: d)
        }
        let name = remoteHEAD ?? ["main", "master"].first { localBranches.contains($0) }
        if let name, localBranches.contains(name) { return BaseBranch(ref: name, name: name) }
        return nil
    }
}

public enum WorktreePath {
    /// Folder for a new worktree: a sibling of the main checkout, "<repo>-<branch>"
    /// ("/src/app" + "feat/x" -> "/src/app-feat-x").
    public static func suggest(main: String, branch: String) -> String {
        let url = URL(fileURLWithPath: main)
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        return url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-\(safe)").path
    }
}
