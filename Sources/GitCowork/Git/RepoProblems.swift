import AppKit
import Foundation
import GitCoworkCore

/// Turns a failed git command into a GitProblem: a plain-words title and
/// explanation, buttons for the obvious next step, and git's output for the
/// details. Which failure it was comes from GitFailure (GitCoworkCore).
extension RepoModel {
    func problem(for error: Error, label: String, args: [String]) -> GitProblem {
        let git = error as? GitError
        let raw = git.map { rawOutput($0.result) } ?? error.localizedDescription
        var p = GitProblem(title: String(localized: "\(L(label)) failed"), message: L("Git stopped. Its own message is under Details."),
                           command: git?.command, output: raw)
        let branch = currentBranch ?? "HEAD"
        let retry = { [weak self] in _ = await self?.perform(label, args) }

        switch GitFailure.classify(raw) {
        case .pushRejected:
            p.title = String(localized: "The remote has commits you don't have yet")
            p.message = String(localized: "Someone pushed to \(status.upstream ?? branch) since your last pull, so git won't push over it. Pull first, then push. Force pushing would overwrite their commits on the server.")
            p.actions = [
                .init(title: L("Force Push…"), role: .destructive) { [weak self] in self?.confirmForcePush() },
                .init(title: L("Pull, Then Push"), role: .primary) { [weak self] in await self?.pullThenPush() },
            ]
        case .protectedBranch:
            p.title = String(localized: "\(branch) is protected on the server")
            p.message = L("The server doesn't allow pushing to this branch directly (branch protection or a server hook). Push your work to a new branch and open a pull request instead.")
            p.actions = [.init(title: L("New Branch…"), role: .primary) { [weak self] in
                guard let self else { return }
                sheet = .newBranch(from: currentBranch ?? "HEAD", label: currentBranch ?? "HEAD")
            }]
        case .staleLease:
            p.title = L("Someone pushed in the meantime")
            p.message = L("Force push with lease only overwrites the server's branch if nobody pushed since your last fetch, and somebody did. Fetch, look at their commits, then decide again.")
            p.actions = [.init(title: L("Fetch"), role: .primary) { [weak self] in await self?.fetch() }]
        case .remoteRefMissing:
            p.isInfo = true
            p.title = L("Already deleted on the server")
            p.message = L("The branch doesn't exist on the server anymore (often deleted after its pull request was merged). The leftover entry here is cleaned up.")
        case .noUpstream:
            p.title = String(localized: "\(branch) doesn't track a remote branch")
            p.message = L("Git doesn't know where to pull from.")
            if let remote = defaultRemote, let ref = remoteBranch(named: "\(remote)/\(branch)") {
                p.message = String(localized: "Git doesn't know where to pull from. \(ref.name) has the same name: track it and pull?")
                p.actions = [.init(title: String(localized: "Track \(ref.name) and Pull"), role: .primary) { [weak self] in
                    guard let self, await perform("Track", ["branch", "--set-upstream-to=\(ref.name)"]) else { return }
                    await pull()
                }]
            }
        case .upstreamGone:
            p.title = String(localized: "\(status.upstream ?? branch) doesn't exist anymore")
            p.message = L("It was probably deleted on the server, for example after its pull request was merged. Nothing was pulled. Push to create it again, or switch to another branch.")
            if let base = baseBranch(), base.name != branch, let ref = localBranch(named: base.name) {
                p.actions = [.init(title: String(localized: "Switch to \(base.name)"), role: .primary) { [weak self] in await self?.checkout(ref) }]
            }
        case .localChangesOverwritten(let files), .untrackedOverwritten(let files):
            let untracked: Bool = if case .untrackedOverwritten = GitFailure.classify(raw) { true } else { false }
            p.title = L("Your uncommitted changes are in the way")
            let list = files.prefix(5).joined(separator: ", ") + (files.count > 5 ? " …" : "")
            p.message = files.isEmpty
                ? L("Git would have to overwrite uncommitted changes, so it stopped. Nothing was lost.")
                : String(localized: "Git would have to overwrite your changes to \(list), so it stopped. Nothing was lost.")
            p.actions = changesInTheWayActions(label: label, args: args, untracked: untracked)
        case .dirtyWorkingCopy:
            p.title = L("Commit or stash your changes first")
            p.message = String(localized: "\(L(label)) needs a clean working copy. Put your changes aside in a stash, run it, and get them back afterwards.")
            p.actions = [.init(title: L("Stash, Run, Restore"), role: .primary) { [weak self] in
                await self?.withStashedChanges(label) { await $0.perform(label, args) }
            }]
        case .conflicts:
            p.title = L("There are conflicts to resolve")
            p.message = L("Resolve the conflicted files in Changes, then continue.")
        case .identityUnknown:
            p.title = L("Git doesn't know who you are yet")
            p.message = L("Commits are signed with a name and email. Set them once, and git-cowork commits right away.")
            p.actions = [.init(title: L("Set Name and Email…"), role: .primary) { [weak self] in
                self?.afterIdentity = retry
                self?.sheet = .identity
            }]
        case .hostKeyUnknown:
            p.title = L("This server's SSH key isn't trusted yet")
            p.message = L("It's the first SSH connection to this server from this Mac. Run the command once in Terminal and answer yes after checking the fingerprint (the server's documentation lists it). The command is copied.")
            let command = "git " + args.joined(separator: " ")
            p.actions = [.init(title: L("Open Terminal"), role: .primary) { [weak self] in
                guard let self else { return }
                External.copy(command)
                External.openTerminal(root.path)
            }]
        case .noWriteAccess:
            p.title = L("Your account can't push here")
            p.message = L("You're signed in, but this account may only read the repository. Ask its owner for write access, or pick an account that has it (status bar, or Settings > Accounts).")
            p.actions = [.init(title: L("Open Accounts"), role: .primary) { Self.openAccountsSettings() }]
        case .signIn:
            p.title = L("The server wants you to sign in")
            p.message = L("Add your account under Settings > Accounts (for SSH remotes, also Create SSH Key there), or set up an SSH key or credential helper for git.")
            if Credentials.shared.hasSeveralOnOneHost {
                p.message += " " + L("If another of your accounts has access, pick it for this repository in the status bar.")
            }
            p.actions = [.init(title: L("Open Accounts"), role: .primary) { Self.openAccountsSettings() }]
        case .offline:
            p.title = L("Can't reach the server")
            p.message = L("Looks like you're offline, or the server isn't answering. Nothing changed. Try again when the connection is back.")
            p.actions = [.init(title: L("Try Again"), role: .primary, run: retry)]
        case .alreadyExists:
            p.title = String(localized: "\(L(label)) failed: the name is taken")
            p.message = L("Something with that name already exists. Pick another name.")
        case .notARepository, .other:
            break
        }
        return p
    }

    /// Changes in the way of a switch: stash them and switch, or (to the
    /// branch's own remote branch) bring them along. Other commands: stash,
    /// run it, and put the changes back.
    private func changesInTheWayActions(label: String, args: [String], untracked: Bool) -> [GitProblem.Action] {
        guard args.first == "switch" || args.first == "checkout" else {
            return [.init(title: L("Stash, Run, Restore"), role: .primary) { [weak self] in
                await self?.withStashedChanges(label) { await $0.perform(label, args) }
            }]
        }
        let target = args.last ?? ""
        let stash = GitProblem.Action(title: L("Stash & Switch"), role: .primary) { [weak self] in
            guard let self else { return }
            let message = String(localized: "Changes on \(currentBranch ?? "HEAD") before switching to \(target)")
            guard await perform("Stash", ["stash", "push", "--include-untracked", "-m", message]) else { return }
            await performUndoable(.checkout, label, args)
        }
        // `switch --merge` carries the changes over, like checking out the same work elsewhere.
        let bring = GitProblem.Action(title: L("Bring Changes Along")) { [weak self] in
            guard let self else { return }
            await perform(label, Array(args.prefix(1)) + ["--merge"] + args.dropFirst())
        }
        // To the branch's own remote branch the changes belong to the same
        // work: bring them along. To another branch: put them aside first.
        // New files in the way can't be merged along; only a stash helps.
        if untracked { return [stash] }
        let sameBranch = target == status.upstream || target == currentBranch
        return sameBranch ? [stash.withRole(.normal), bring.withRole(.primary)] : [bring, stash]
    }

    /// Stashes uncommitted changes, runs `action`, then puts them back. If
    /// putting them back conflicts, the stash is kept and Changes says so.
    func withStashedChanges(_ label: String, _ action: (RepoModel) async -> Bool) async {
        let dirty = !status.isClean
        if dirty {
            guard await perform("Stash", ["stash", "push", "--include-untracked", "-m", String(localized: "Before \(L(label))")]) else { return }
        }
        let ok = await action(self)
        guard dirty else { return }
        if ok {
            await popStash()
        } else {
            alert = AlertItem(title: L("Your changes are in a stash"),
                              message: L("They were put aside before the command ran. Pop the newest stash in the sidebar once you're done."))
        }
    }

    /// Pull, and push if that left nothing to resolve.
    func pullThenPush() async {
        await pull()
        guard status.conflicted.isEmpty, operation == nil, status.behind == 0 else { return }
        await push()
    }

    static func openAccountsSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func rawOutput(_ r: GitResult) -> String {
        let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if err.isEmpty { return out.isEmpty ? String(localized: "git exited with code \(r.exitCode)") : out }
        return out.isEmpty ? err : out + "\n" + err
    }
}

extension GitProblem.Action {
    func withRole(_ role: Role) -> GitProblem.Action {
        GitProblem.Action(title: title, role: role, run: run)
    }
}
