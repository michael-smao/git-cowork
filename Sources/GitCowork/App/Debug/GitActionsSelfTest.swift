import AppKit
import Foundation
import GitCoworkCore

// Debug builds only (see DebugSnapshot.swift).
#if DEBUG

/// End-to-end check of the git actions that touch the user's files or the
/// remote, with real git and no UI:
///     GITCOWORK_ACTIONS_SELFTEST=/tmp/some-empty-dir .build/debug/GitCowork
/// Pull with uncommitted changes (fast-forward, merge, rebase, a conflicting
/// autostash), merge, rejected and force pushes, deleting branches here and on
/// the remote, removing worktrees, checking out a branch another worktree
/// holds, what a stash holds, Ignore, a second remote, and the `file:` /
/// `change:` search. A second clone plays the teammate who pushes in between.
@MainActor
enum GitActionsSelfTest {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["GITCOWORK_ACTIONS_SELFTEST"] else { return }
        Task {
            let ok = await run(in: URL(fileURLWithPath: dir))
            print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
            exit(ok ? 0 : 1)
        }
    }

    private static var failures = 0

    private static func check(_ cond: Bool, _ what: String) {
        print((cond ? "  ok   " : "  FAIL ") + what)
        if !cond { failures += 1 }
    }

    private static func write(_ text: String, _ name: String, in dir: URL) {
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private static func read(_ name: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    /// Waits until `done` holds (actions that run in their own Task).
    private static func settle(_ model: RepoModel, until done: () -> Bool) async {
        for _ in 0..<400 where !done() {
            try? await Task.sleep(for: .milliseconds(25))
        }
        while model.busy != nil { try? await Task.sleep(for: .milliseconds(25)) }
    }

    static func run(in dir: URL) async -> Bool {
        let fm = FileManager.default
        // Only ever delete a folder this test created itself (it holds a marker file).
        let marker = dir.appendingPathComponent(".git-cowork-actions-selftest")
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if !contents.isEmpty {
            guard fm.fileExists(atPath: marker.path) else {
                print("Refusing to use \(dir.path): it isn't empty and wasn't created by the self-test.")
                return false
            }
            try? fm.removeItem(at: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fm.createFile(atPath: marker.path, contents: nil)
        let remote = dir.appendingPathComponent("remote.git")
        let repo = dir.appendingPathComponent("repo")
        let mate = dir.appendingPathComponent("teammate")

        await sh(["init", "-q", "--bare", "-b", "main", remote.path], in: dir)
        await sh(["init", "-q", "-b", "main", repo.path], in: dir)
        for r in [repo] {
            await sh(["config", "user.email", "me@x.com"], in: r)
            await sh(["config", "user.name", "Me"], in: r)
        }
        await sh(["remote", "add", "origin", remote.path], in: repo)
        write("one\n", "a.txt", in: repo)
        await sh(["add", "."], in: repo)
        await sh(["commit", "-qm", "one"], in: repo)
        await sh(["push", "-q", "-u", "origin", "main"], in: repo)
        await sh(["clone", "-q", remote.path, mate.path], in: dir)
        await sh(["config", "user.email", "mate@x.com"], in: mate)
        await sh(["config", "user.name", "Mate"], in: mate)

        /// The teammate commits a file and pushes.
        func matePushes(_ file: String, _ text: String) async {
            await sh(["pull", "-q", "--ff-only"], in: mate)
            write(text, file, in: mate)
            await sh(["add", "."], in: mate)
            await sh(["commit", "-qm", "mate: \(file)"], in: mate)
            await sh(["push", "-q", "origin", "main"], in: mate)
        }
        func commitHere(_ file: String, _ text: String) async {
            write(text, file, in: repo)
            await sh(["add", "--", file], in: repo)
            await sh(["commit", "-qm", "me: \(file)"], in: repo)
        }
        func head() async -> String { await sh(["rev-parse", "HEAD"], in: repo) }
        func remoteMain() async -> String { await sh(["rev-parse", "refs/heads/main"], in: remote) }
        func stashCount() async -> Int { await sh(["stash", "list"], in: repo).split(separator: "\n").count }

        let model = RepoModel(root: repo)
        await model.load()

        print("1. pull fast-forwards and keeps uncommitted changes")
        await matePushes("b.txt", "b\n")
        write("one, edited\n", "a.txt", in: repo)
        await model.refresh()
        await model.pull()
        check(await head() == remoteMain(), "main moved to the remote")
        check(read("a.txt", in: repo) == "one, edited\n", "the uncommitted edit is still there")
        check(await stashCount() == 0, "no stash left behind")
        check(model.problem == nil && model.alert == nil, "nothing to report")

        print("2. pull with both sides moved asks; Rebase keeps changes")
        await matePushes("c.txt", "c\n")
        await commitHere("d.txt", "d\n")
        await model.refresh()
        await model.pull()
        let rebaseAsk = model.confirmation
        check(rebaseAsk?.alternativeTitle == "Rebase" && rebaseAsk?.confirmTitle == "Merge", "asks Merge or Rebase")
        check(rebaseAsk?.destructive == false, "the question isn't styled as destructive")
        model.confirmation = nil
        await rebaseAsk?.alternative?()
        check(await sh(["rev-parse", "HEAD~1"], in: repo) == remoteMain(), "rebased: my commit sits on the remote's")
        check(read("d.txt", in: repo) == "d\n", "my commit's file is there")
        check(read("a.txt", in: repo) == "one, edited\n", "the uncommitted edit survived the rebase")
        check(await stashCount() == 0, "no stash left behind")

        print("3. Merge joins both sides")
        await matePushes("e.txt", "e\n")
        await commitHere("f.txt", "f\n")
        await model.refresh()
        await model.pull()
        let mergeAsk = model.confirmation
        model.confirmation = nil
        await mergeAsk?.action()
        check(await sh(["rev-list", "--parents", "-n", "1", "HEAD"], in: repo).split(separator: " ").count == 3, "a merge commit with two parents")
        check(read("a.txt", in: repo) == "one, edited\n", "the uncommitted edit survived the merge")
        await model.push()
        check(await head() == remoteMain(), "pushed")

        print("4. pull whose changes can't go back cleanly loses nothing")
        await sh(["checkout", "-q", "--", "a.txt"], in: repo)
        await matePushes("a.txt", "one, theirs\n")
        write("one, mine\n", "a.txt", in: repo)
        await model.refresh()
        await model.pull()
        check(await head() == remoteMain(), "main moved to the remote")
        let a = read("a.txt", in: repo) ?? ""
        let kept = a.contains("one, mine")
        let stashed = await stashCount() > 0
        check(kept || stashed, "my edit is in the file or in a stash")
        print("       file has my edit: \(kept), stash kept: \(stashed), conflicted: \(model.status.conflicted.map(\.path))")
        print("       problem: \(model.problem?.title ?? "none"), alert: \(model.alert?.title ?? "none")")
        check(!stashed || model.stashConflict != nil, "if the edit went to a stash, Changes says so")
        check(model.selection == .workingCopy, "Changes is shown")
        model.problem = nil; model.alert = nil; model.stashConflict = nil
        await sh(["reset", "-q", "--hard"], in: repo)
        await sh(["stash", "clear"], in: repo)
        await model.refresh()

        print("5. merge a branch with uncommitted changes")
        await sh(["switch", "-q", "-c", "topic"], in: repo)
        await commitHere("g.txt", "g\n")
        await sh(["switch", "-q", "main"], in: repo)
        write("two\n", "h.txt", in: repo)
        await model.refresh()
        await model.merge("topic")
        check(read("g.txt", in: repo) == "g\n", "merged")
        check(read("h.txt", in: repo) == "two\n", "the new uncommitted file is still there")
        try? fm.removeItem(at: repo.appendingPathComponent("h.txt"))
        await model.push()

        print("6. a rejected push explains and offers Pull, Then Push")
        await matePushes("i.txt", "i\n")
        await commitHere("j.txt", "j\n")
        await model.refresh()
        await model.push()
        let rejected = model.problem
        check(rejected?.title == "The remote has commits you don't have yet", "says the remote moved")
        check(rejected?.actions.map(\.title) == ["Force Push…", "Pull, Then Push"], "offers Force Push… and Pull, Then Push")
        model.problem = nil
        await rejected?.actions.last?.run()
        let afterPull = model.confirmation
        check(afterPull?.alternativeTitle == "Rebase", "the pull asks Merge or Rebase first")
        model.confirmation = nil
        await afterPull?.alternative?()
        await model.push()
        check(await head() == remoteMain(), "then the push goes through")

        print("7. force push asks, and refuses when the remote moved since the last fetch")
        await matePushes("k.txt", "k\n")
        let mates = await remoteMain()
        await commitHere("l.txt", "l\n")
        await model.refresh()
        model.confirmForcePush()
        let force = model.confirmation
        check(force?.destructive == true && force?.title == "Force push main?", "asks first, as destructive")
        model.confirmation = nil
        await force?.action()
        check(await remoteMain() == mates, "stale lease: the teammate's commit is still on the remote")
        model.problem = nil; model.alert = nil
        await model.fetch()
        model.confirmForcePush()
        let force2 = model.confirmation
        model.confirmation = nil
        await force2?.action()
        check(await remoteMain() == head(), "after a fetch it replaces the remote branch")
        await sh(["pull", "-q", "--rebase=false", "--no-edit"], in: mate)
        await sh(["reset", "-q", "--hard", "origin/main"], in: mate)

        print("8. delete a branch here and on the remote")
        await sh(["switch", "-q", "-c", "feat"], in: repo)
        await commitHere("m.txt", "m\n")
        await sh(["push", "-q", "-u", "origin", "feat"], in: repo)
        await sh(["switch", "-q", "main"], in: repo)
        await model.refresh()
        if let feat = model.localBranch(named: "feat") {
            model.deleteBranch(feat)
            await settle(model) { model.confirmation != nil }
            let ask = model.confirmation
            check(ask?.title == "Delete feat?", "asks first")
            check(ask?.message.contains("nothing is lost") == true, "says nothing is lost (it's on the remote)")
            check(ask?.alternativeTitle == "Delete Here and on origin", "offers deleting it on origin too")
            model.confirmation = nil
            await ask?.alternative?()
            check(await sh(["branch", "--list", "feat"], in: repo).isEmpty, "gone here")
            check(await sh(["branch", "--list", "feat"], in: remote).isEmpty, "gone on the remote")
        } else {
            check(false, "feat is listed")
        }

        print("8b. pulling a branch without upstream offers to track its remote branch")
        await sh(["push", "-q", "origin", "main:refs/heads/loose"], in: repo)
        await sh(["fetch", "-q", "origin"], in: repo)
        await sh(["switch", "-q", "--no-track", "-c", "loose", "origin/loose"], in: repo)
        await model.refresh()
        await model.pull()
        check(model.problem?.actions.first?.title == "Track origin/loose and Pull", "offers Track origin/loose and Pull")
        model.problem = nil
        await sh(["switch", "-q", "main"], in: repo)
        await model.refresh()

        print("9. a local-only branch says what is lost")
        await sh(["switch", "-q", "-c", "only-here"], in: repo)
        await commitHere("n.txt", "n\n")
        await sh(["switch", "-q", "main"], in: repo)
        await model.refresh()
        if let only = model.localBranch(named: "only-here") {
            model.deleteBranch(only)
            await settle(model) { model.confirmation != nil }
            check(model.confirmation?.message.contains("1 commit exists only on this branch") == true, "says 1 commit goes away")
            check(model.confirmation?.alternativeTitle == nil, "no remote option without a remote branch")
            model.confirmation = nil
        } else {
            check(false, "only-here is listed")
        }

        print("10. deleting a remote branch that's already gone cleans up")
        await sh(["push", "-q", "origin", "main:refs/heads/old"], in: repo)
        await sh(["fetch", "-q", "origin"], in: repo)
        await sh(["push", "-q", "origin", "--delete", "old"], in: mate)
        await model.refresh()
        if let old = model.remoteBranch(fullName: "origin/old") {
            model.deleteBranch(old)
            let ask = model.confirmation
            model.confirmation = nil
            await ask?.action()
            check(await sh(["for-each-ref", "refs/remotes/origin/old"], in: repo).isEmpty, "the stale origin/old is gone")
            print("       says: \(model.problem?.title ?? "nothing") (info: \(model.problem?.isInfo ?? false))")
            model.problem = nil
        } else {
            check(false, "origin/old is listed")
        }

        print("11. remove worktrees")
        let wt1 = dir.appendingPathComponent("wt-clean").path
        let wt2 = dir.appendingPathComponent("wt-dirty").path
        await sh(["worktree", "add", "-q", "-b", "w1", wt1], in: repo)
        await sh(["worktree", "add", "-q", "-b", "w2", wt2], in: repo)
        write("unsaved\n", "a.txt", in: URL(fileURLWithPath: wt2))
        await model.refresh()
        if let main = model.worktrees.first(where: \.isMain) {
            model.removeWorktree(main)
            check(model.confirmation == nil, "the main worktree can't be removed")
        }
        if let w = model.worktrees.first(where: { $0.path.hasSuffix("wt-clean") }) {
            model.removeWorktree(w)
            let ask = model.confirmation
            check(ask?.message.contains("Deletes the folder") == true, "clean: says it deletes the folder, the branch stays")
            model.confirmation = nil
            await ask?.action()
            await settle(model) { !fm.fileExists(atPath: wt1) }
            check(!fm.fileExists(atPath: wt1), "clean worktree's folder is gone")
            check(!(await sh(["branch", "--list", "w1"], in: repo)).isEmpty, "its branch stays")
        } else {
            check(false, "wt-clean is listed")
        }
        await settle(model) { model.worktreeInfo[wt2] != nil }
        if let w = model.worktrees.first(where: { $0.path.hasSuffix("wt-dirty") }) {
            model.removeWorktree(w)
            let ask = model.confirmation
            check(ask?.message.contains("will be lost") == true, "dirty: warns that the changes will be lost")
            model.confirmation = nil
            await ask?.action()
            await settle(model) { !fm.fileExists(atPath: wt2) }
            check(!fm.fileExists(atPath: wt2), "dirty worktree's folder is gone after confirming")
        } else {
            check(false, "wt-dirty is listed")
        }
        check(fm.fileExists(atPath: repo.appendingPathComponent("a.txt").path), "the main worktree is untouched")

        print("12. checkout of a branch another worktree holds opens that worktree")
        let wt3 = dir.appendingPathComponent("wt-three").path
        await sh(["worktree", "add", "-q", "-b", "w3", wt3], in: repo)
        await model.refresh()
        var opened: String?
        model.openWorktree = { opened = $0 }
        if let w3 = model.localBranch(named: "w3") {
            await model.checkout(w3)
            check(opened.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                  == URL(fileURLWithPath: wt3).resolvingSymlinksInPath().path, "asked the window to open wt-three")
            check(await sh(["branch", "--show-current"], in: repo) == "main", "this worktree stayed on main")
        } else {
            check(false, "w3 is listed")
        }
        model.openWorktree = nil

        print("13. a stash shows its changes and its new files, and Pop brings them back")
        await sh(["reset", "-q", "--hard"], in: repo)
        await sh(["clean", "-qfd"], in: repo)
        write("one, stashed\n", "a.txt", in: repo)
        write("brand new\n", "new.txt", in: repo)
        await model.refresh()
        await model.stash(message: "half done")
        check(model.status.isClean, "the working copy is clean after stashing")
        if let stash = model.stashes.first, let contents = await model.stashContents(stash) {
            check(stash.title == "half done" && stash.branch == "main", "the stash knows its message and branch")
            check(contents.files.map(\.path) == ["a.txt", "new.txt"], "lists the changed file, then the new one")
            let changed = contents.files[0], added = contents.files[1]
            check(contents.source(of: changed).id == stash.sha, "the changed file is diffed against the commit the stash was made on")
            check(contents.source(of: added).id != stash.sha && contents.source(of: added).parents.isEmpty,
                  "the new file comes from the stash's commit of untracked files")
            let diff = String(decoding: await DiffLoader.commit(contents.source(of: changed), file: changed, root: repo), as: UTF8.self)
            check(diff.contains("+one, stashed"), "the changed file's diff shows the stashed line")
            let newDiff = String(decoding: await DiffLoader.commit(contents.source(of: added), file: added, root: repo), as: UTF8.self)
            check(newDiff.contains("+brand new"), "the new file's diff shows its content")
            model.selection = .stash(stash.sha)
            await model.popStash(stash)
            check(model.stashes.isEmpty, "Pop removed the stash")
            check(model.selection == .workingCopy, "and the panel moved on to the changes it brought back")
            check(read("a.txt", in: repo) == "one, stashed\n" && read("new.txt", in: repo) == "brand new\n", "both files are back")
        } else {
            check(false, "the stash is listed and readable")
        }
        await sh(["reset", "-q", "--hard"], in: repo)
        await sh(["clean", "-qfd"], in: repo)

        print("14. Ignore adds to .gitignore and the files leave Changes")
        try? fm.createDirectory(at: repo.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        write("noise\n", "junk.log", in: repo)
        write("x\n", "tmp/cache.bin", in: repo)
        await model.refresh()
        check(Set(model.status.untracked.map(\.path)) == ["junk.log", "tmp/cache.bin"], "both new files are listed")
        await model.ignore([GitIgnore.pattern(forFile: "junk.log")])
        check(model.status.untracked.map(\.path).sorted() == [".gitignore", "tmp/cache.bin"], "junk.log is gone, .gitignore is new")
        await model.ignore([GitIgnore.pattern(forFolder: "tmp")])
        check(model.status.untracked.map(\.path) == [".gitignore"], "the folder's file is gone too")
        await model.ignore([GitIgnore.pattern(forFile: "junk.log"), GitIgnore.pattern(forFolder: "tmp")])
        check(read(".gitignore", in: repo) == "/junk.log\n/tmp/\n", "each pattern is in the file once")
        check(fm.fileExists(atPath: repo.appendingPathComponent("junk.log").path), "the ignored file itself is untouched")
        await sh(["clean", "-qfdx"], in: repo)
        await model.refresh()

        print("15. add, fetch, rename, edit and remove a second remote")
        let fork = dir.appendingPathComponent("fork.git")
        await sh(["clone", "-q", "--bare", remote.path, fork.path], in: dir)
        check(await model.addRemote(name: "fork", url: fork.path), "added")
        check(model.remoteNames == ["fork", "origin"] || model.remoteNames == ["origin", "fork"], "both remotes are listed")
        await model.fetch(remote: "fork")
        check(model.remoteBranch(fullName: "fork/main") != nil, "its branches are here after the fetch")
        await sh(["config", "cowork.remote", "fork"], in: repo)
        check(await model.editRemote("fork", name: "mine", url: fork.path), "renamed")
        check(model.remoteNames.contains("mine") && !model.remoteNames.contains("fork"), "listed under the new name")
        check(model.remoteBranch(fullName: "mine/main") != nil, "its branches follow")
        check(await sh(["config", "--get", "cowork.remote"], in: repo) == "mine", "tasks keep syncing with it under the new name")
        check(await model.editRemote("mine", name: "mine", url: mate.path), "URL changed")
        check(model.remotes.first { $0.name == "mine" }?.url == mate.path, "the new URL is listed")
        check(await !model.addRemote(name: "mine", url: fork.path, quiet: true), "a second remote of the same name is refused")
        model.problem = nil
        await sh(["config", "--unset", "cowork.remote"], in: repo)
        await sh(["branch", "-q", "--track", "follows-mine", "mine/main"], in: repo)
        await model.refresh()
        model.removeRemote("mine")
        let removal = model.confirmation
        check(removal?.title == "Remove remote mine?" && removal?.destructive == true, "removing asks first, as destructive")
        check(removal?.message.contains("1 local branch pushes to and pulls from it") == true, "and says a local branch follows it")
        model.confirmation = nil
        await removal?.action()
        check(model.remoteNames == ["origin"], "only origin is left")
        check(model.remoteBranch(fullName: "mine/main") == nil, "its branches are gone")
        check(model.localBranch(named: "follows-mine") != nil, "the local branch stays")
        check(await head() == sh(["rev-parse", "origin/main"], in: repo), "origin and main are untouched")

        print("16. file: and change: search the whole history")
        write("let zebraStripe = 1\n", "zoo.swift", in: repo)
        await sh(["add", "--", "zoo.swift"], in: repo)
        await sh(["commit", "-qm", "Add the zoo"], in: repo)
        await model.refresh()
        await model.searchHistory(CommitQuery("file:ZOO"))
        check(model.historySearch?.commits.map(\.subject) == ["Add the zoo"], "file: finds the commit by a part of the path, whatever the case")
        check(model.historySearch?.running == false, "and says it's done")
        await model.searchHistory(CommitQuery("change:ZEBRAstripe"))
        check(model.historySearch?.commits.map(\.subject) == ["Add the zoo"], "change: finds the commit that added the text")
        await model.searchHistory(CommitQuery("change:\"no such text anywhere\""))
        check(model.historySearch?.commits.isEmpty == true, "nothing found is an empty result")
        await model.searchHistory(CommitQuery("file:g.txt change:g"))
        check(model.historySearch?.commits.map(\.subject) == ["me: g.txt"], "both terms together narrow it down")
        await model.searchHistory(CommitQuery("zoo"))
        check(model.historySearch == nil, "plain words clear the search")
        check(model.commit(await head())?.subject == "Add the zoo", "loaded commits are still found by sha")
        let slow = Task { await model.searchHistory(CommitQuery("change:zebra")) }
        slow.cancel()
        await slow.value
        check(model.historySearch?.commits.isEmpty == true, "a search that was typed over leaves no result behind")

        print("17. a branch whose upstream has another name asks where to push")
        await sh(["push", "-q", "origin", "HEAD:refs/heads/feat/remote-name"], in: repo)
        await sh(["fetch", "-q", "origin"], in: repo)
        await sh(["switch", "-q", "-c", "feat-local", "--track", "origin/feat/remote-name"], in: repo)
        await commitHere("h.txt", "h\n")
        await model.refresh()
        await model.push()
        let whereAsk = model.confirmation
        check(whereAsk?.alternative != nil && whereAsk?.destructive == false, "asks: the upstream, or a new branch of the same name")
        check(await sh(["rev-parse", "refs/heads/feat/remote-name"], in: remote) != (await head()), "nothing pushed before answering")
        model.confirmation = nil
        await whereAsk?.action()
        check(await sh(["rev-parse", "refs/heads/feat/remote-name"], in: remote) == (await head()), "pushed to the upstream")
        await commitHere("i.txt", "i\n")
        await model.refresh()
        await model.push()
        let secondAsk = model.confirmation
        model.confirmation = nil
        await secondAsk?.alternative?()
        check(await sh(["rev-parse", "refs/heads/feat-local"], in: remote) == (await head()), "or to a new branch of the same name")
        await model.refresh()
        check(model.status.upstream == "origin/feat-local", "which it follows from now on")
        await model.push()
        check(model.confirmation == nil && model.problem == nil, "then pushes without asking")

        model.stopWatching()
        return failures == 0
    }
}

#endif
