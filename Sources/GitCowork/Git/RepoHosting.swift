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
