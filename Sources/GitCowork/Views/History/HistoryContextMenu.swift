import AppKit
import GitCoworkCore

// Right-click menu on a row.
extension HistoryTableCoordinator {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table else { return }
        fill(menu, row: table.clickedRow)
    }

    /// The row's menu, for the badge list that hovers over the table. With
    /// `onlyBadge`, the branch items are only those of that badge.
    func contextMenu(forRow row: Int, onlyBadge: String? = nil) -> NSMenu? {
        let menu = NSMenu()
        fill(menu, row: row, onlyBadge: onlyBadge)
        return menu.items.isEmpty ? nil : menu
    }

    /// Always the same sections in the same order, so an item is always in
    /// the same place: the branch, bringing changes together, working with
    /// others, new things from the commit, changing history, copying, and
    /// last whatever removes something. Empty sections are left out.
    private func fill(_ menu: NSMenu, row: Int, onlyBadge: String? = nil) {
        guard row >= 0, row < rows.count else { return }
        let model = self.model
        let i: Int
        switch rows[row] {
        case .wip:
            menu.addItem(ActionItem("Write Commit Message") { [weak self] in _ = self?.focusSummaryIfWIP(row: row) })
            menu.addItem(ActionItem("Stash Changes…") { model.sheet = .stash })
            return
        case .otherWIP(let path):
            var open: [NSMenuItem] = []
            var remove: [NSMenuItem] = []
            if let wt = model.worktrees.first(where: { $0.path == path }) {
                let openHere = self.openHere, openInNewTab = self.openInNewTab
                open.append(ActionItem("Open Worktree") { openHere(wt.path) })
                open.append(ActionItem("Open Worktree in New Tab") { openInNewTab(wt.path) })
                if !wt.isMain {
                    remove.append(ActionItem("Remove Worktree…") { model.removeWorktree(wt) })
                }
            }
            MenuSections.add([
                open,
                [ActionItem("Open in Terminal") { External.openTerminal(path) },
                 ActionItem("Open in Editor") { External.openEditor(path) },
                 ActionItem("Reveal in Finder") { External.reveal(path) }],
                [ActionItem("Copy Path") { External.copy(path) }],
                remove,
            ], to: menu)
            return
        case .commit(let index):
            guard index < commits.count else { return }
            i = index
        }
        let commit = commits[i]
        let branches = badges(forCommit: i).filter { $0.kind == .branch && (onlyBadge == nil || $0.name == onlyBadge) }
        let commitItems = commitSections(commit)
        guard branches.count > 1 else {
            // One branch: its items and the commit's share the sections.
            let b = branches.first.map { branchSections($0, commit: commit) } ?? BranchSections()
            MenuSections.add([
                b.branch,
                b.integrate + commitItems.integrate,
                b.collaborate + commitItems.collaborate,
                commitItems.create,
                commitItems.history,
                b.copy + commitItems.copy,
                b.remove,
            ], to: menu)
            return
        }
        // Several branches: one submenu each, with its sections in the same order.
        var submenus: [NSMenuItem] = []
        for badge in branches {
            let b = branchSections(badge, commit: commit)
            let item = NSMenuItem(title: badge.name, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            MenuSections.add([b.branch, b.integrate, b.collaborate, b.copy, b.remove], to: sub)
            item.submenu = sub
            submenus.append(item)
        }
        MenuSections.add([
            submenus,
            commitItems.integrate,
            commitItems.collaborate,
            commitItems.create,
            commitItems.history,
            commitItems.copy,
        ], to: menu)
    }

    /// A branch badge's items, by section. A local branch and its remote share them.
    private struct BranchSections {
        var branch: [NSMenuItem] = []
        var integrate: [NSMenuItem] = []
        var collaborate: [NSMenuItem] = []
        var copy: [NSMenuItem] = []
        var remove: [NSMenuItem] = []
    }

    private func branchSections(_ badge: GraphBadge, commit: Commit) -> BranchSections {
        let model = self.model
        let refs = refsByCommit[commit.id] ?? []
        let current = model.currentBranch ?? "HEAD"
        let local = refs.first { $0.kind == .localBranch && badge.refNames.contains($0.name) }
        let remote = refs.first { $0.kind == .remoteBranch && badge.refNames.contains($0.name) }
        var s = BranchSections()
        if let local {
            // Checked out in another worktree: open or remove that one. Git
            // won't check it out here as well.
            if let wt = model.sidebarOtherWorktree(for: local.name) {
                let openHere = self.openHere, openInNewTab = self.openInNewTab
                s.branch.append(ActionItem("Open Worktree for \(local.name)") { openHere(wt.path) })
                s.branch.append(ActionItem("Open Worktree for \(local.name) in New Tab") { openInNewTab(wt.path) })
                if !wt.isMain {
                    s.remove.append(ActionItem("Remove Worktree for \(local.name)…") { model.removeWorktree(wt) })
                    s.remove.append(ActionItem("Remove Worktree and Delete \(local.name)…") {
                        model.removeWorktreeAndDeleteBranch(wt, branch: local)
                    })
                }
            } else if !local.isHead {
                s.branch.append(ActionItem("Checkout \(local.name)") { Task { await model.checkout(local) } })
            }
            // Also for a branch that isn't checked out: it moves up to its remote branch.
            if let source = model.pullSource(for: local), local.isHead || model.sidebarOtherWorktree(for: local.name) == nil {
                s.branch.append(ActionItem("Pull \(local.name)") { Task { await model.pull(branch: local, from: source) } })
            }
            s.branch.append(ActionItem("Push \(local.name)") { Task { await model.push(branch: local.name) } })
            // No upstream yet (or it's gone), but a remote branch of that name: track it.
            if local.upstream == nil || local.upstreamGone {
                for candidate in model.remoteBranches where candidate.branchNameWithoutRemote == local.name {
                    let name = candidate.name
                    s.branch.append(ActionItem("Set Upstream to \(name)") { Task { await model.setUpstream(local.name, to: name) } })
                }
            }
            s.branch.append(ActionItem("Rename \(local.name)…") { model.sheet = .renameBranch(local.name) })
        } else if let remote {
            // Remote-only here. If a local branch of that name exists elsewhere,
            // checking out switches to it, so say where it is.
            if let other = model.localBranches.first(where: { $0.name == badge.name }) {
                if !other.isHead {
                    let at = String(other.target.prefix(7))
                    s.branch.append(ActionItem("Checkout \(other.name) (local, at \(at))") { Task { await model.checkout(other) } })
                }
                // The remote branch is ahead here: bring the local one up to it.
                if other.isHead || model.sidebarOtherWorktree(for: other.name) == nil {
                    s.branch.append(ActionItem("Pull \(other.name)") { Task { await model.pull(branch: other, from: remote) } })
                }
            } else {
                s.branch.append(ActionItem("Checkout \(remote.name)") { Task { await model.checkout(remote) } })
            }
        }
        if !(local?.isHead ?? false) {
            let target = local?.name ?? remote?.name ?? badge.name
            s.integrate.append(ActionItem("Merge \(target) into \(current)") { Task { await model.merge(target) } })
            s.integrate.append(ActionItem("Rebase \(current) onto \(target)") { Task { await model.rebase(onto: target) } })
        }
        let branch = badge.name
        if let links = model.links(for: nil) {
            if let pull = model.pull(forBranch: branch) {
                s.collaborate.append(ActionItem("Open \(links.pullRequestTerm) #\(pull.number) on \(links.host)") { External.browse(pull.webURL) })
            } else if branch != model.baseBranch()?.name, model.canCreatePull(remote: nil) {
                s.collaborate.append(ActionItem("Create \(links.pullRequestTerm)…") { model.sheet = .createPull(branch: branch) })
            }
        }
        s.collaborate.append(ActionItem("Request Review of \(branch)…") { model.sheet = .requestReview(branch: branch) })
        for task in tasksByBranch[branch] ?? [] {
            let id = task.id
            s.collaborate.append(ActionItem("Open Task \(id)") {
                model.centerMode = .board
                model.coworkSelection = .task(id)
            })
        }
        // The name without its remote, as for a branch only on the server.
        s.copy.append(ActionItem("Copy Branch Name") { External.copy(branch) })
        if let links = model.links(for: nil) {
            // Only for a branch the server has.
            if remote != nil || local?.upstream != nil && local?.upstreamGone == false, let url = links.branchURL(branch) {
                s.copy.append(ActionItem("Copy Link to Branch") { External.copy(url.absoluteString) })
            }
            if let pull = model.pull(forBranch: branch), let url = pull.webURL {
                s.copy.append(ActionItem("Copy Link to \(links.pullRequestTerm) #\(pull.number)") { External.copy(url.absoluteString) })
            }
        }
        // Always asks first; for a local branch the question also offers its
        // remote branch. Not for the checked-out branch, one in another
        // worktree (that one has Remove Worktree), or the remote's default branch.
        if let local, !local.isHead, model.sidebarOtherWorktree(for: local.name) == nil {
            s.remove.append(ActionItem("Delete \(local.name)…") { model.deleteBranch(local) })
        } else if let remote, let name = remote.remoteName, model.remoteDefaults[name] != remote.branchNameWithoutRemote {
            s.remove.append(ActionItem("Delete \(remote.name)…") { model.deleteBranch(remote) })
        }
        return s
    }

    /// The commit's own items, by section.
    private func commitSections(_ commit: Commit) -> (integrate: [NSMenuItem], collaborate: [NSMenuItem], create: [NSMenuItem],
                                                      history: [NSMenuItem], copy: [NSMenuItem]) {
        let model = self.model
        let sha = commit.id
        let short = commit.shortID
        let current = model.currentBranch ?? "HEAD"

        let reset = NSMenuItem(title: String(localized: "Reset \(current) to this commit"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(ActionItem("Soft – keep all changes") { model.reset(to: sha, mode: .soft) })
        sub.addItem(ActionItem("Mixed – keep working copy but reset index") { model.reset(to: sha, mode: .mixed) })
        sub.addItem(ActionItem("Hard – discard all changes…") { model.reset(to: sha, mode: .hard) })
        reset.submenu = sub

        var copy: [NSMenuItem] = [
            ActionItem("Copy SHA") { External.copy(sha) },
            ActionItem("Copy Message") { External.copy(commit.subject) },
        ]
        if let links = model.links(for: nil), let url = links.commitURL(sha) {
            copy.append(ActionItem("Copy Link to Commit") { External.copy(url.absoluteString) })
            copy.append(ActionItem("Open Commit on \(links.host)") { External.browse(url) })
        }
        // A release for each tag here; without a tag, one with a new tag.
        let tags = (refsByCommit[sha] ?? []).filter { $0.kind == .tag }.map(\.name).sorted()
        var collaborate: [NSMenuItem] = []
        var create: [NSMenuItem] = [
            ActionItem("Create Branch Here…") { model.sheet = .newBranch(from: sha, label: short) },
            ActionItem("Create Worktree Here…") { model.sheet = .addWorktree(base: sha) },
            ActionItem("Create Tag Here…") { model.sheet = .newTag(sha: sha) },
        ]
        if let links = model.links(for: nil) {
            for tag in tags {
                if model.canCreateRelease {
                    collaborate.append(ActionItem("Create Release for \(tag)…") { model.sheet = .createRelease(tag: tag, sha: sha) })
                } else if let url = links.newReleaseURL(tag: tag) {
                    collaborate.append(ActionItem("Create Release for \(tag) on \(links.host)") { External.browse(url) })
                }
            }
            if tags.isEmpty, model.canCreateRelease {
                create.append(ActionItem("Create Release Here…") { model.sheet = .createRelease(tag: nil, sha: sha) })
            }
        }
        create.append(ActionItem("Checkout \(short) (detached)") { Task { await model.checkoutCommit(sha) } })
        return (
            integrate: [ActionItem("Cherry-pick into \(current)") { Task { await model.cherryPick(sha) } }],
            collaborate: collaborate,
            create: create,
            history: [ActionItem("Revert Commit") { Task { await model.revert(sha) } }, reset],
            copy: copy
        )
    }
}

/// Fills a menu section by section, with one separator between sections
/// that have items.
enum MenuSections {
    static func add(_ sections: [[NSMenuItem]], to menu: NSMenu) {
        for section in sections where !section.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String.LocalizationValue, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: String(localized: title), action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
