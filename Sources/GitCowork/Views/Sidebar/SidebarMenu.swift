import GitCoworkCore
import SwiftUI

/// Right-click menu for any sidebar item.
struct SidebarMenu: View {
    let model: RepoModel
    let id: String
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void

    var body: some View {
        if id.hasPrefix("ref:"), let ref = model.refs.first(where: { "ref:" + $0.fullName == id }) {
            switch ref.kind {
            case .localBranch: localBranch(ref)
            case .remoteBranch: remoteBranch(ref)
            case .tag: tag(ref)
            }
        } else if id.hasPrefix("wt:"), let wt = model.worktrees.first(where: { "wt:" + $0.path == id }) {
            worktree(wt)
        } else if id.hasPrefix("stash:"), let s = model.stashes.first(where: { "stash:" + $0.selector == id }) {
            Button("Apply") { Task { await model.applyStash(s) } }
            Button("Pop") { Task { await model.popStash(s) } }
            Divider()
            Button("Delete…", role: .destructive) { model.dropStash(s) }
        } else if id.hasPrefix("task:"), let task = model.cowork.task(String(id.dropFirst(5))) {
            Button("Open Task") { openTask(task.id) }
            if let branch = task.branch, let ref = model.localBranches.first(where: { $0.name == branch }), !ref.isHead {
                if let wt = model.sidebarOtherWorktree(for: branch) {
                    Button("Open Worktree for \(branch)") { openHere(wt.path) }
                } else {
                    Button("Checkout \(branch)") { Task { await model.checkout(ref) } }
                }
            }
            Divider()
            Button("Copy ID") { External.copy(task.id) }
        } else if id.hasPrefix("review:"), let review = model.cowork.review(String(id.dropFirst(7))) {
            Button("Open Review") {
                model.centerMode = .reviews
                model.coworkSelection = .review(review.id)
            }
            if let taskID = review.taskID {
                Button("Open Task \(taskID)") { openTask(taskID) }
            }
            Divider()
            Button("Copy Branch Name") { External.copy(review.branch) }
        } else if id.hasPrefix("pull:"), let status = model.hostStatus,
                  let pull = status.pulls.first(where: { "pull:\($0.number)" == id }) {
            pullMenu(pull, host: status.links.host)
        } else if id.hasPrefix("remote:"), let remote = model.remotes.first(where: { "remote:" + $0.name == id }) {
            remoteMenu(remote)
        }
    }

    @ViewBuilder
    private func remoteMenu(_ remote: Remote) -> some View {
        Button("Fetch \(remote.name)") { Task { await model.fetch(remote: remote.name) } }
        Divider()
        Button("Edit Remote…") { model.sheet = .editRemote(remote.name) }
        Button("Copy URL") { External.copy(remote.url) }
        if let links = model.links(for: remote.name), let url = URL(string: links.webBase) {
            Button("Open on \(links.host)") { External.browse(url) }
        }
        Divider()
        Button("Remove Remote…", role: .destructive) { model.removeRemote(remote.name) }
    }

    @ViewBuilder
    private func pullMenu(_ pull: HostPull, host: String) -> some View {
        Button("Open on \(host)") { External.browse(pull.webURL) }
        // Only by a ref that exists: the name comes from the host.
        if !pull.isFromFork {
            if let wt = model.sidebarOtherWorktree(for: pull.branch) {
                Button("Open Worktree for \(pull.branch)") { openHere(wt.path) }
            } else if let ref = model.localBranches.first(where: { $0.name == pull.branch }) ?? model.remoteBranches.first(where: { $0.branchNameWithoutRemote == pull.branch }),
                      !ref.isHead {
                Button("Checkout \(pull.branch)") { Task { await model.checkout(ref) } }
            }
        }
        if let url = pull.webURL {
            Divider()
            Button("Copy Link") { External.copy(url.absoluteString) }
        }
    }

    private var current: String { model.currentBranch ?? "HEAD" }

    // Branch menus have the same sections, in the same order, as the
    // history's menu: the branch, merging and rebasing, pull requests and
    // reviews, new things from it, copying, and last whatever removes something.

    @ViewBuilder
    private func localBranch(_ ref: Ref) -> some View {
        // A branch checked out in another worktree can't be switched to or deleted here.
        let otherWorktree = model.sidebarOtherWorktree(for: ref.name)
        if let wt = otherWorktree {
            Button("Open Worktree") { openHere(wt.path) }
            Button("Open Worktree in New Tab") { openInNewTab(wt.path) }
            Button("Push") { Task { await model.push(branch: ref.name) } }
        } else if !ref.isHead {
            Button("Checkout") { Task { await model.checkout(ref) } }
            if let source = model.pullSource(for: ref) {
                Button("Pull") { Task { await model.pull(branch: ref, from: source) } }
            }
            Button("Push") { Task { await model.push(branch: ref.name) } }
        } else {
            Button("Pull") { Task { await model.pull() } }
            Button("Push") { Task { await model.push() } }
        }
        Button("Rename…") { model.sheet = .renameBranch(ref.name) }
        Divider()
        if !ref.isHead {
            Button("Merge \(ref.name) into \(current)") { Task { await model.merge(ref.name) } }
            Button("Rebase \(current) onto \(ref.name)") { Task { await model.rebase(onto: ref.name) } }
            Divider()
        }
        let remote = ref.upstream?.split(separator: "/").first.map(String.init)
        pullLink(branch: ref.name, remote: remote)
        cowork(branch: ref.name)
        Button("New Branch from \(ref.name)…") { model.sheet = .newBranch(from: ref.name, label: ref.name) }
        // Git won't add a second worktree for a branch that is already checked out somewhere.
        if !model.worktrees.contains(where: { $0.branch == ref.name }) {
            Button("Create Worktree…") { model.sheet = .addWorktree(base: ref.name) }
        }
        Divider()
        Button("Copy Name") { External.copy(ref.name) }
        branchLink(branch: ref.name, remote: remote)
        if let wt = otherWorktree {
            Divider()
            if wt.isMain {
                Button("Delete… (checked out in a worktree)") {}.disabled(true)
            } else {
                Button("Remove Worktree…", role: .destructive) { model.removeWorktree(wt) }
                Button("Remove Worktree and Delete \(ref.name)…", role: .destructive) {
                    model.removeWorktreeAndDeleteBranch(wt, branch: ref)
                }
            }
        } else if !ref.isHead {
            Divider()
            Button("Delete…", role: .destructive) { model.deleteBranch(ref) }
        }
    }

    @ViewBuilder
    private func remoteBranch(_ ref: Ref) -> some View {
        let local = ref.branchNameWithoutRemote
        if let wt = model.sidebarOtherWorktree(for: local) {
            Button("Open Worktree for \(local)") { openHere(wt.path) }
        } else {
            Button("Checkout as Local Branch") { Task { await model.checkout(ref) } }
        }
        Divider()
        Button("Merge \(ref.name) into \(current)") { Task { await model.merge(ref.name) } }
        Button("Rebase \(current) onto \(ref.name)") { Task { await model.rebase(onto: ref.name) } }
        Divider()
        pullLink(branch: local, remote: ref.remoteName)
        cowork(branch: local)
        Button("New Branch from \(ref.name)…") { model.sheet = .newBranch(from: ref.name, label: ref.name) }
        Button("Create Worktree…") { model.sheet = .addWorktree(base: ref.name) }
        Divider()
        Button("Copy Name") { External.copy(ref.name) }
        branchLink(branch: local, remote: ref.remoteName)
        Divider()
        Button("Delete on \(ref.remoteName ?? "remote")…", role: .destructive) { model.deleteBranch(ref) }
    }

    /// "Request Review…" and "Open Task CW-…" for tasks linked to the branch.
    @ViewBuilder
    private func cowork(branch: String) -> some View {
        Button("Request Review…") { model.sheet = .requestReview(branch: branch) }
        ForEach(model.sidebarTasks(forBranch: branch)) { task in
            Button("Open Task \(task.id)") { openTask(task.id) }
        }
        Divider()
    }

    private func openTask(_ id: String) {
        openCoworkTarget("tasks/\(id)", model: model)
    }

    @ViewBuilder
    private func tag(_ ref: Ref) -> some View {
        Button("Checkout (detached)") { Task { await model.checkout(ref) } }
        Button("Push Tag") { Task { await model.pushTag(ref.name) } }
        if let links = model.links(for: nil) {
            Divider()
            if model.canCreateRelease {
                Button("Create Release…") { model.sheet = .createRelease(tag: ref.name, sha: ref.target) }
            } else if let url = links.newReleaseURL(tag: ref.name) {
                Button("Create Release on \(links.host)") { External.browse(url) }
            }
        }
        Divider()
        Button("Copy Name") { External.copy(ref.name) }
        Divider()
        Button("Delete…", role: .destructive) { model.deleteTag(ref.name) }
    }

    @ViewBuilder
    private func worktree(_ wt: Worktree) -> some View {
        if WorktreeRemovals.shared.contains(wt.path) {
            Button("Removing…") {}.disabled(true)
            Button("Copy Path") { External.copy(wt.path) }
        } else {
            worktreeActions(wt)
        }
    }

    @ViewBuilder
    private func worktreeActions(_ wt: Worktree) -> some View {
        if !model.sidebarIsCurrent(wt) {
            Button("Open Here") { openHere(wt.path) }
            Button("Open in New Tab") { openInNewTab(wt.path) }
            Divider()
        }
        Button("Open in Terminal") { External.openTerminal(wt.path) }
        Button("Open in Editor") { External.openEditor(wt.path) }
        Button("Reveal in Finder") { External.reveal(wt.path) }
        Divider()
        if let branch = wt.branch {
            pullLink(branch: branch, remote: nil)
        }
        Button("Copy Path") { External.copy(wt.path) }
        if let branch = wt.branch {
            branchLink(branch: branch, remote: nil)
        }
        if !wt.isMain {
            Divider()
            Button("Prune Stale Worktrees") { Task { await model.pruneWorktrees() } }
            // This window's own worktree too: it then moves to the main worktree.
            Button("Remove Worktree…", role: .destructive) { model.removeWorktree(wt, leave: openHere) }
                .disabled(model.sidebarIsCurrent(wt) && !model.canLeaveForMainWorktree)
            if !model.sidebarIsCurrent(wt), let branch = wt.branch,
               let ref = model.localBranches.first(where: { $0.name == branch }) {
                Button("Remove Worktree and Delete \(branch)…", role: .destructive) {
                    model.removeWorktreeAndDeleteBranch(wt, branch: ref)
                }
            }
        }
    }

    /// The branch's pull request, or creating one.
    @ViewBuilder
    private func pullLink(branch: String, remote: String?) -> some View {
        if let links = model.links(for: remote) {
            let base = model.baseBranch()?.name
            if let pull = model.pull(forBranch: branch), remote == nil || remote == model.defaultRemote {
                Button("Open \(links.pullRequestTerm) #\(pull.number) on \(links.host)") { External.browse(pull.webURL) }
            } else if branch != base, model.canCreatePull(remote: remote) {
                Button("Create \(links.pullRequestTerm)…") { model.sheet = .createPull(branch: branch) }
            } else if branch != base, let url = links.newPullRequestURL(branch: branch, base: base) {
                Button("Create \(links.pullRequestTerm) on \(links.host)") { External.browse(url) }
            }
        }
    }

    /// The branch on the host's website.
    @ViewBuilder
    private func branchLink(branch: String, remote: String?) -> some View {
        if let links = model.links(for: remote), let url = links.branchURL(branch) {
            Button("Open Branch on \(links.host)") { External.browse(url) }
        }
    }
}
