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
            if let wt = model.worktrees.first(where: { $0.path == path }) {
                let openHere = self.openHere, openInNewTab = self.openInNewTab
                menu.addItem(ActionItem("Open Worktree") { openHere(wt.path) })
                menu.addItem(ActionItem("Open Worktree in New Tab") { openInNewTab(wt.path) })
                if !wt.isMain {
                    menu.addItem(ActionItem("Remove Worktree…") { model.removeWorktree(wt) })
                }
                menu.addItem(.separator())
            }
            menu.addItem(ActionItem("Open in Terminal") { External.openTerminal(path) })
            menu.addItem(ActionItem("Open in Editor") { External.openEditor(path) })
            menu.addItem(ActionItem("Reveal in Finder") { External.reveal(path) })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Copy Path") { External.copy(path) })
            return
        case .commit(let index):
            guard index < commits.count else { return }
            i = index
        }
        let commit = commits[i]
        let sha = commit.id
        let short = commit.shortID
        let current = model.currentBranch ?? "HEAD"
        let refs = refsByCommit[sha] ?? []

        // One group per branch badge: a local branch and its remote share items.
        for badge in badges(forCommit: i) where badge.kind == .branch && (onlyBadge == nil || badge.name == onlyBadge) {
            let local = refs.first { $0.kind == .localBranch && badge.refNames.contains($0.name) }
            let remote = refs.first { $0.kind == .remoteBranch && badge.refNames.contains($0.name) }
            if let local {
                if !local.isHead {
                    menu.addItem(ActionItem("Checkout \(local.name)") { Task { await model.checkout(local) } })
                }
                // Also for a branch that isn't checked out: it moves up to its remote branch.
                if let source = model.pullSource(for: local), local.isHead || model.sidebarOtherWorktree(for: local.name) == nil {
                    menu.addItem(ActionItem("Pull \(local.name)") { Task { await model.pull(branch: local, from: source) } })
                }
                menu.addItem(ActionItem("Push \(local.name)") { Task { await model.push(branch: local.name) } })
                // Checked out in another worktree: open or remove that one.
                if let wt = model.sidebarOtherWorktree(for: local.name) {
                    let openHere = self.openHere, openInNewTab = self.openInNewTab
                    menu.addItem(ActionItem("Open Worktree for \(local.name)") { openHere(wt.path) })
                    menu.addItem(ActionItem("Open Worktree for \(local.name) in New Tab") { openInNewTab(wt.path) })
                    if !wt.isMain {
                        menu.addItem(ActionItem("Remove Worktree for \(local.name)…") { model.removeWorktree(wt) })
                    }
                }
            } else if let remote {
                // Remote-only here. If a local branch of that name exists elsewhere,
                // checking out switches to it, so say where it is.
                if let other = model.localBranches.first(where: { $0.name == badge.name }) {
                    if !other.isHead {
                        let at = String(other.target.prefix(7))
                        menu.addItem(ActionItem("Checkout \(other.name) (local, at \(at))") { Task { await model.checkout(other) } })
                    }
                    // The remote branch is ahead here: bring the local one up to it.
                    if other.isHead || model.sidebarOtherWorktree(for: other.name) == nil {
                        menu.addItem(ActionItem("Pull \(other.name)") { Task { await model.pull(branch: other, from: remote) } })
                    }
                } else {
                    menu.addItem(ActionItem("Checkout \(remote.name)") { Task { await model.checkout(remote) } })
                }
            }
            if !(local?.isHead ?? false) {
                let target = local?.name ?? remote?.name ?? badge.name
                menu.addItem(ActionItem("Merge \(target) into \(current)") { Task { await model.merge(target) } })
                menu.addItem(ActionItem("Rebase \(current) onto \(target)") { Task { await model.rebase(onto: target) } })
            }
            let branch = badge.name
            menu.addItem(ActionItem("Request Review of \(branch)…") { model.sheet = .requestReview(branch: branch) })
            if let links = model.links(for: nil) {
                if let pull = model.pull(forBranch: branch) {
                    menu.addItem(ActionItem("Open \(links.pullRequestTerm) #\(pull.number) on \(links.host)") { External.browse(pull.webURL) })
                } else if branch != model.baseBranch()?.name, model.canCreatePull(remote: nil) {
                    menu.addItem(ActionItem("Create \(links.pullRequestTerm)…") { model.sheet = .createPull(branch: branch) })
                }
            }
            for task in tasksByBranch[branch] ?? [] {
                let id = task.id
                menu.addItem(ActionItem("Open Task \(id)") {
                    model.centerMode = .board
                    model.coworkSelection = .task(id)
                })
            }
            menu.addItem(.separator())
        }

        menu.addItem(ActionItem("Checkout \(short) (detached)") { Task { await model.checkoutCommit(sha) } })
        menu.addItem(ActionItem("Create Branch Here…") { model.sheet = .newBranch(from: sha, label: short) })
        menu.addItem(ActionItem("Create Tag Here…") { model.sheet = .newTag(sha: sha) })
        menu.addItem(ActionItem("Create Worktree Here…") { model.sheet = .addWorktree(base: sha) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Cherry-pick into \(current)") { Task { await model.cherryPick(sha) } })
        menu.addItem(ActionItem("Revert Commit") { Task { await model.revert(sha) } })

        let reset = NSMenuItem(title: String(localized: "Reset \(current) to this commit"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(ActionItem("Soft – keep all changes") { model.reset(to: sha, mode: .soft) })
        sub.addItem(ActionItem("Mixed – keep working copy but reset index") { model.reset(to: sha, mode: .mixed) })
        sub.addItem(ActionItem("Hard – discard all changes…") { model.reset(to: sha, mode: .hard) })
        reset.submenu = sub
        menu.addItem(reset)

        menu.addItem(.separator())
        menu.addItem(ActionItem("Copy SHA") { External.copy(sha) })
        menu.addItem(ActionItem("Copy Message") { External.copy(commit.subject) })
        if let links = model.links(for: nil), let url = links.commitURL(sha) {
            menu.addItem(ActionItem("Open Commit on \(links.host)") { External.browse(url) })
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
