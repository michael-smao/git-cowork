import Foundation
import GitCoworkCore

/// Which remote the shared tasks sync with. One rule for the app and the
/// `git cowork` tool, so both always talk to the same remote. The choice is
/// `git config cowork.remote` (per repository, all worktrees), independent
/// of the checked-out branch, so a branch tracking a fork's `upstream` never
/// sends the team's tasks there.
public enum CoworkRemote {
    public static let configKey = "cowork.remote"

    /// `configured` if it's a remote here; else origin if it has cowork data;
    /// else another remote that has it; else origin; else the first remote.
    public static func resolve(remotes: [String], configured: String?, hasCoworkRef: (String) -> Bool) -> String? {
        if let configured, remotes.contains(configured) { return configured }
        guard !remotes.isEmpty else { return nil }
        if remotes.contains("origin"), hasCoworkRef("origin") { return "origin" }
        if let r = remotes.first(where: hasCoworkRef) { return r }
        return remotes.contains("origin") ? "origin" : remotes[0]
    }

    /// Remote names in `git for-each-ref --format=%(refname) refs/cowork/remotes/`
    /// output ("refs/cowork/remotes/<remote>/main"; remote names may contain "/").
    public static func remotesWithData(_ refs: String) -> Set<String> {
        let prefix = "refs/cowork/remotes/", suffix = "/main"
        return Set(refs.split(separator: "\n").compactMap { line in
            guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count > prefix.count + suffix.count else { return nil }
            return String(line.dropFirst(prefix.count).dropLast(suffix.count))
        })
    }

    public struct Choice: Equatable, Sendable {
        public let remote: String?
        /// Picked because it already has the team's tasks, and not yet in
        /// `git config cowork.remote`: worth writing there (see `remember`).
        public let worthRemembering: Bool

        public init(remote: String?, worthRemembering: Bool) {
            self.remote = remote
            self.worthRemembering = worthRemembering
        }
    }

    /// Reads the repo's remotes, `git config cowork.remote` and the fetched cowork refs.
    public static func choose(root: URL, git: GitExecutor) async -> Choice {
        let remotes = await git.git(["remote"], in: root).text.split(separator: "\n").map(String.init)
        let configured = await git.git(["config", "--get", configKey], in: root).line
        let withData = remotesWithData(await git.git(["for-each-ref", "--format=%(refname)", "refs/cowork/remotes/"], in: root).text)
        let pick = resolve(remotes: remotes, configured: configured.isEmpty ? nil : configured,
                           hasCoworkRef: withData.contains)
        return Choice(remote: pick, worthRemembering: pick.map { $0 != configured && withData.contains($0) } ?? false)
    }

    /// The git command that writes the choice to the repository's config,
    /// where both the app and the tool read it.
    public static func rememberArgs(_ remote: String) -> [String] {
        ["config", "--local", configKey, remote]
    }
}
