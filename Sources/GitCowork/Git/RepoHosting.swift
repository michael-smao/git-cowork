import Foundation
import GitCoworkCore

/// Pull requests and CI from the remote's host. See HostStatus.
extension RepoModel {
    /// Called when the window opens, when the app comes to the front, on the
    /// fetch tick while in front, and after a fetch, pull or push.
    func updateHostStatus(force: Bool = false) async {
        guard !isStopped else { return }
        let status = links(for: nil).flatMap(HostStatus.of)
        if status !== hostStatus { hostStatus = status }
        guard let status else { return }
        // The same account git uses for this repository (RepoAccounts).
        let config = await git.tryRun(["config", "--get-regexp", RepoAccounts.configPattern], in: root) ?? ""
        let host = status.links.host.lowercased()
        status.use(RepoAccounts.choices(accounts: AccountStore.shared.accounts, config: config)
            .first { SSHKey.sshHost($0.host) == host }?.current)
        await status.refresh(wanted: commitsWithCI, force: force)
    }

    /// What's pushed of each tracked branch, and the base branch.
    private var commitsWithCI: Set<String> {
        let upstreams = Set(localBranches.compactMap(\.upstream))
        var commits = Set(remoteBranches.filter { upstreams.contains($0.name) }.map(\.target))
        if let base = branch(named: baseBranchName) { commits.insert(base.target) }
        return commits
    }

    func pull(forBranch name: String) -> HostPull? { hostStatus?.pull(forBranch: name) }
    func ciState(_ sha: String?) -> CIState? { sha.flatMap { hostStatus?.ci[$0]?.state } }

    /// Whether this remote is the one pull requests are read from, so the
    /// app can create one itself instead of opening the host's page.
    func canCreatePull(remote: String?) -> Bool {
        guard hostStatus?.canCreatePulls == true else { return false }
        return remote == nil || remote == defaultRemote
    }

    /// Whether the app can create a release itself (signed in to the host),
    /// rather than opening the host's page.
    var canCreateRelease: Bool { hostStatus?.canCreatePulls == true }

    /// The commits since the tag before `target`, as release notes. Empty
    /// when there's no earlier tag: then it would be the whole history.
    func releaseNotes(upTo target: String) async -> String {
        guard let previous = await git.tryLine(["describe", "--tags", "--abbrev=0", "--end-of-options", "\(target)^"], in: root),
              !previous.isEmpty else { return "" }
        let log = await git.tryRun(["log", "--no-merges", "--reverse", "--format=%s", "--end-of-options",
                                    "refs/tags/\(previous)..\(target)"], in: root) ?? ""
        return ReleaseDraft.notes(subjects: log.split(separator: "\n").map(String.init))
    }

    /// Pushes the tag to the default remote; nothing happens if it's there
    /// already. False (with `lastProblem`) when it failed or there's no remote.
    func pushTagForRelease(_ name: String) async -> Bool {
        guard let remote = defaultRemote else {
            lastProblem = GitProblem(title: L("No remote"), message: L("Add a remote to push the tag to."))
            return false
        }
        return await perform("Push tag", ["push", remote, "refs/tags/\(name)"], quiet: true)
    }

    /// Makes the tag at `sha` if it doesn't exist yet, pushes it, and creates
    /// the release. Returns the release's page. Throws with git's or the
    /// host's message; a tag made here stays when a later step fails.
    func createRelease(tag: String, at sha: String, title: String, notes: String,
                       draft: Bool, prerelease: Bool) async throws -> URL? {
        guard let status = hostStatus else { throw AccountError(message: L("Not signed in to this repository's host.")) }
        if !tags.contains(where: { $0.name == tag }) {
            guard await createTag(tag, at: sha, message: "", quiet: true) else {
                throw AccountError(message: lastProblemText ?? String(localized: "Couldn't create the tag \(tag)."))
            }
        }
        guard await pushTagForRelease(tag) else {
            throw AccountError(message: lastProblemText ?? String(localized: "Couldn't push \(tag)."))
        }
        return try await status.createRelease(tag: tag, title: title, notes: notes, draft: draft, prerelease: prerelease)
    }

    /// Branches a request can target, without the branch itself. Keeps `current` listed.
    func baseOptions(for branch: String, keeping current: String) -> [String] {
        var names = localBranches.map(\.name)
        if let d = baseBranch()?.name, !names.contains(d) { names.append(d) }
        if !current.isEmpty, !names.contains(current) { names.append(current) }
        return names.filter { $0 != branch }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Why others can't see this branch on the remote yet, if they can't.
    func pushProblem(for branch: String) -> String? {
        let local = localBranches.first { $0.name == branch }
        let onRemote = local?.upstream != nil || remoteBranches.contains { $0.branchNameWithoutRemote == branch }
        if !onRemote { return String(localized: "\(branch) isn't on the remote yet. Push it so others can fetch it.") }
        if let local, local.ahead > 0 {
            return local.ahead == 1 ? String(localized: "1 commit on \(branch) not pushed yet.")
                                    : String(localized: "\(local.ahead) commits on \(branch) not pushed yet.")
        }
        return nil
    }
}
