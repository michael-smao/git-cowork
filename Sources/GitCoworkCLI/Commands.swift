import CoworkKit
import Foundation
import GitCoworkCLIKit
import GitCoworkCore

/// One run of `git cowork <command>`. The rules (task order, who's waiting,
/// which branch a task starts on, the base branch) are the app's, from
/// GitCoworkCore and CoworkKit.
struct Commands {
    let args: Args
    let repo: CoworkRepo
    let remote: String?
    var json: Bool { args.flag("json") }

    // MARK: Reading

    func list() async throws {
        if args.flag("sync") { await syncQuietly() }
        let snap = await repo.snapshot()
        var tasks = snap.tasks
        if let s = args.value("status") {
            let status = try Self.status(s)
            tasks = tasks.filter { $0.status == status }
        } else if !args.flag("all") {
            tasks = tasks.filter { $0.status != .done }
        }
        if args.flag("mine") { tasks = tasks.filter { $0.assignee?.lowercased() == repo.me.id } }
        if let a = args.value("assignee") {
            let email = try resolve(a, in: snap)
            tasks = tasks.filter { $0.assignee?.lowercased() == email?.lowercased() }
        }
        for l in args.all("label") { tasks = tasks.filter { $0.labels.contains(l) } }
        tasks = TaskOrder.sorted(tasks)
        if json { return Output.json(tasks.map { Output.task($0) }) }
        if tasks.isEmpty { print("No tasks."); return }
        tasks.forEach { print(Output.taskLine($0)) }
    }

    func show() async throws {
        if args.flag("sync") { await syncQuietly() }
        let id = try args.arg(1, "task or review id")
        let snap = await repo.snapshot()
        if let t = snap.task(id: id) {
            let comments = snap.comments[t.commentParent] ?? []
            return json ? Output.json(Output.task(t, comments: comments)) : Output.showTask(t, comments: comments)
        }
        if let r = snap.review(id: id) {
            let comments = snap.comments[r.commentParent] ?? []
            return json ? Output.json(Output.review(r, comments: comments)) : Output.showReview(r, comments: comments)
        }
        throw CLIError.failed("No task or review \(id).")
    }

    func reviews() async throws {
        if args.flag("sync") { await syncQuietly() }
        var list = await repo.snapshot().reviews
        let me = repo.me.id
        if args.flag("waiting") {
            list = list.filter { $0.isWaiting(on: me) }
        } else if args.flag("mine") {
            list = list.filter { $0.requester.lowercased() == me }
        } else if !args.flag("all") {
            list = list.filter { $0.status == .open }
        }
        list.sort { $0.updated > $1.updated }
        if json { return Output.json(list.map { Output.review($0) }) }
        if list.isEmpty { print("No reviews."); return }
        list.forEach { print(Output.reviewLine($0)) }
    }

    func inbox() async throws {
        if args.flag("sync") { await syncQuietly() }
        let snap = await repo.snapshot()
        let known = Array(Set(snap.tasks.flatMap { [$0.author, $0.assignee].compactMap { $0 } } + snap.reviews.map(\.requester)))
        let items = CoworkInbox.items(for: repo.me.email, in: snap, knownEmails: known)
        if json { return Output.json(items.map(Output.inbox)) }
        if items.isEmpty { print("Nothing new."); return }
        for i in items { print("\(Output.date(i.date))  \(i.title)  — \(i.detail)") }
    }

    // MARK: Writing

    func new() async throws {
        let title = args.text(from: 1)
        guard !title.isEmpty else { throw CLIError.usage("missing task title") }
        let status = try args.value("status").map(Self.status) ?? .todo
        let snap = await repo.snapshot()
        let assignee = try args.value("assign").flatMap { try resolve($0, in: snap) }
        let (t, edit) = CoworkEdit.newTask(title: title, status: status, assignee: assignee,
                                           labels: args.all("label"), body: args.value("body") ?? "",
                                           author: repo.me.email, in: snap)
        try await repo.apply(edit)
        await syncAfterWrite()
        json ? Output.json(Output.task(t)) : print(t.id)
    }

    func assign(_ who: String) async throws {
        try await edit(assignee: .some(resolve(who, in: await repo.snapshot())))
    }

    /// `edit <id>`, plus the shortcuts `move`, `assign`, `done`.
    func edit(status: TaskStatus? = nil, assignee: String?? = nil) async throws {
        let snap = await repo.snapshot()
        let id = try task(args.arg(1, "task id"), in: snap).id
        let newStatus = try status ?? args.value("status").map(Self.status)
        let newAssignee: String?? = try assignee ?? args.value("assign").map { try resolve($0, in: snap) }
        let title = args.value("title"), body = args.value("body"), branch = args.value("branch")
        if let branch, branch != "none", !RefName.isValid(branch) {
            throw CLIError.usage("\(branch) isn't a valid branch name")
        }
        let labels = args.all("label")
        let changed = try await repo.apply(CoworkEdit.updateTasks([id: { t in
            if let title { t.title = title }
            if let body { t.body = body }
            if let newStatus { t.status = newStatus }
            if let newAssignee { t.assignee = newAssignee }
            if let branch { t.branch = branch == "none" ? nil : branch }
            for l in labels {
                if l.hasPrefix("-") { t.labels.removeAll { $0 == String(l.dropFirst()) } }
                else {
                    let name = l.hasPrefix("+") ? String(l.dropFirst()) : l
                    if !t.labels.contains(name) { t.labels.append(name) }
                }
            }
        }], message: "Update \(id)"))
        if changed { await syncAfterWrite() }
        try await printTask(id)
    }

    func comment() async throws {
        let id = try args.arg(1, "task or review id")
        let body = args.text(from: 2)
        guard !body.isEmpty else { throw CLIError.usage("missing comment text") }
        let snap = await repo.snapshot()
        let parent: String
        if let t = snap.task(id: id) { parent = t.commentParent }
        else if let r = snap.review(id: id) { parent = r.commentParent }
        else { throw CLIError.failed("No task or review \(id).") }
        let (c, edit) = CoworkEdit.comment(on: parent, body: body, by: repo.me)
        try await repo.apply(edit)
        await syncAfterWrite()
        json ? Output.json(Output.comment(c)) : print("Commented on \(id).")
    }

    func requestReview() async throws {
        let branch = try args.arg(1, "branch")
        guard RefName.isValid(branch) else { throw CLIError.usage("\(branch) isn't a valid branch name") }
        let snap = await repo.snapshot()
        let reviewers = try args.all("to").flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            .compactMap { try resolve($0, in: snap) }
        guard !reviewers.isEmpty else { throw CLIError.usage("--to needs at least one reviewer") }
        let localTip = await repo.sha("refs/heads/\(branch)")
        let remoteTip = remote == nil ? nil : await repo.sha("refs/remotes/\(remote!)/\(branch)")
        guard let tip = localTip ?? remoteTip else { throw CLIError.failed("No branch \(branch) here.") }
        var base = args.value("base") ?? ""
        if base.isEmpty { base = await RepoState.load(repo).baseName }
        guard RefName.isValid(base) else { throw CLIError.usage("\(base) isn't a valid branch name") }
        guard base != branch else {
            throw CLIError.usage("\(branch) is the base branch; review another branch, or pass --base")
        }
        let task = try args.value("task").map { try self.task($0, in: snap).id } ?? snap.tasks.first { $0.linkedBranch == branch }?.id
        let lastSubject = await repo.git.git(["log", "-1", "--format=%s", tip], in: repo.root).line
        let (r, edit) = CoworkEdit.requestReview(branch: branch, base: base, title: args.value("title") ?? lastSubject,
                                                 reviewers: reviewers, body: args.value("body") ?? "",
                                                 taskID: task, requester: repo.me.email, in: snap)
        try await repo.apply(edit)
        await syncAfterWrite()
        json ? Output.json(Output.review(r)) : print(r.id)
    }

    func verdict(_ v: ReviewVerdict) async throws {
        let id = try args.arg(1, "review id")
        let text = args.text(from: 2)
        if v == .changesRequested && text.isEmpty { throw CLIError.usage("say what should change") }
        guard let r = await repo.snapshot().review(id: id) else { throw CLIError.failed("No review \(id).") }
        try await repo.apply(CoworkEdit.verdict(v, on: r, comment: text, by: repo.me))
        await syncAfterWrite()
        if json {
            let snap = await repo.snapshot()
            let updated = snap.review(id: r.id) ?? r
            return Output.json(Output.review(updated, comments: snap.comments[updated.commentParent] ?? []))
        }
        print(v == .approved ? "Approved \(r.branch)." : "Asked for changes on \(r.branch).")
    }

    /// Checks out (or creates) the task's branch, here or in a new worktree,
    /// links it, moves the task to In Progress and assigns it to me. Same
    /// branch and git command as the app's Start Task (TaskStart).
    func start() async throws {
        let snap = await repo.snapshot()
        let t = try task(args.arg(1, "task id"), in: snap)
        guard let name = TaskStart.branchName(for: t) else { throw CLIError.failed("\(t.id) has no usable branch name.") }
        let state = await RepoState.load(repo)
        let wantsWorktree = args.flag("worktree") || args.value("worktree-path") != nil

        var path: String?
        if wantsWorktree, let existing = state.worktrees.first(where: { $0.branch == name }) {
            path = existing.path   // already has its own worktree: reuse it, like the app
        } else {
            let hasLocal = state.refs.contains { $0.kind == .localBranch && $0.name == name }
            let remoteRef = BranchLookup.remote(named: name, in: state.refs, preferred: state.defaultRemote ?? "origin",
                                                remotes: state.remotes)
            if wantsWorktree {
                // A path typed by the user is relative to where they are, not the repo root.
                let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                path = args.value("worktree-path").map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL.path }
                    ?? WorktreePath.suggest(main: state.mainPath ?? repo.root.path, branch: name)
            }
            try await run(TaskStart.plan(branch: name, hasLocal: hasLocal, remoteBranch: remoteRef?.name,
                                         base: state.base?.ref ?? "HEAD", worktreePath: path))
        }
        try await repo.apply(CoworkEdit.markStarted(id: t.id, branch: name, me: repo.me.email, in: snap))
        await syncAfterWrite()
        if json {
            var o: [String: Any] = ["id": t.id, "branch": name]
            o["worktree"] = path ?? NSNull()
            return Output.json(o)
        }
        print(path.map { "Started \(t.id) on \(name) in \($0)" } ?? "Started \(t.id) on \(name)")
    }

    func sync() async throws {
        guard let remote else { throw CLIError.failed("No remote to sync with.") }
        if try await repo.sync(remote: remote) { print("Synced with \(remote).") }
        else { throw CLIError.failed("The remote kept changing; try again.") }
    }

    // MARK: Helpers

    static func status(_ s: String) throws -> TaskStatus {
        switch s.lowercased() {
        case "backlog": .backlog
        case "todo", "to-do", "to do": .todo
        case "doing", "progress", "in-progress", "in progress", "started": .doing
        case "review", "in-review", "in review": .review
        case "done", "closed": .done
        default: throw CLIError.usage("unknown status \(s) (backlog, todo, doing, review, done)")
        }
    }

    /// "me", "none", an email, or a handle of someone the shared data knows (see People).
    private func resolve(_ who: String, in snap: CoworkSnapshot) throws -> String? {
        try People.resolve(who, me: repo.me.email, known: People.known(in: snap) + [repo.me])
    }

    private func task(_ id: String, in snap: CoworkSnapshot) throws -> CoworkTask {
        guard let t = snap.task(id: id) else { throw CLIError.failed("No task \(id).") }
        return t
    }

    private func printTask(_ id: String) async throws {
        guard let t = await repo.snapshot().task(id: id) else { return }
        json ? Output.json(Output.task(t)) : print(Output.taskLine(t))
    }

    private func run(_ cmd: [String]) async throws {
        let r = await repo.git.git(cmd, in: repo.root)
        guard r.ok else { throw CLIError.failed(CoworkRepo.message(r, cmd.first ?? "git")) }
    }

    /// Writes push right away so teammates see them; a failed push is only a warning
    /// (the change is saved locally and goes out with the next sync).
    private func syncAfterWrite() async {
        guard !args.flag("no-sync"), let remote else { return }
        do {
            if try await repo.sync(remote: remote) == false {
                FileHandle.standardError.write(Data("git-cowork: saved locally; the remote kept changing, run `git cowork sync` later.\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("git-cowork: saved locally, but sync failed: \(error.localizedDescription)\n".utf8))
        }
    }

    private func syncQuietly() async {
        guard let remote else { return }
        _ = try? await repo.sync(remote: remote)
    }
}

/// The repo's branches, remotes and worktrees, read the way the app reads them
/// (Parsers), for picking branches and the base like the app does.
struct RepoState {
    var refs: [Ref] = []
    var remoteDefaults: [String: String] = [:]
    var remotes: [String] = []
    var worktrees: [Worktree] = []
    var upstream: String?

    static func load(_ repo: CoworkRepo) async -> RepoState {
        let git = repo.git, root = repo.root
        var s = RepoState()
        let list = Parsers.parseRefs(await git.git(["for-each-ref", Parsers.refFormat, "refs/heads", "refs/remotes"], in: root).text)
        s.refs = list.refs
        s.remoteDefaults = list.remoteDefaults
        s.remotes = await git.git(["remote"], in: root).text.split(separator: "\n").map(String.init)
        s.worktrees = Parsers.parseWorktrees(await git.git(["worktree", "list", "--porcelain"], in: root).text)
        let up = await git.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: root)
        s.upstream = up.ok && !up.line.isEmpty ? up.line : nil
        return s
    }

    var mainPath: String? { worktrees.first(where: \.isMain)?.path }
    var defaultRemote: String? { BranchLookup.defaultRemote(upstream: upstream, remotes: remotes) }

    var base: BaseBranch? {
        let remote = defaultRemote
        return BaseBranch.resolve(remote: remote, remoteHEAD: remoteDefaults[remote ?? "origin"],
                                  remoteBranches: refs.filter { $0.kind == .remoteBranch }.map(\.name),
                                  localBranches: refs.filter { $0.kind == .localBranch }.map(\.name))
    }

    /// Plain name of the base branch, for review requests ("main" without a hint).
    var baseName: String { base?.name ?? BaseBranch.fallbackName }
}
