import AppKit
import CoworkKit
import Foundation
import GitCoworkCore
import Observation

/// Resolves symlinks like realpath(3). Unlike URL.resolvingSymlinksInPath it keeps
/// /private, so paths match what git prints.
func realPath(_ path: String) -> String {
    guard let p = realpath(path, nil) else { return path }
    defer { free(p) }
    return String(cString: p)
}

/// State of one open worktree: refs, history, working copy, and the actions on it.
/// UI state types are in RepoUIState.swift, the background fetch in RepoAutoFetch.swift.
@MainActor @Observable
final class RepoModel {
    let root: URL
    let git = GitRunner.shared

    private(set) var gitDir: URL?
    private(set) var commonDir: URL?
    private(set) var loadError: String?
    private(set) var isLoaded = false

    // Repository data
    private(set) var commits: [Commit] = []
    private(set) var graph: [GraphRow] = []
    private(set) var commitIndex: [String: Int] = [:]
    private(set) var refs: [Ref] = []
    private(set) var refsByCommit: [String: [Ref]] = [:]
    private(set) var remoteDefaults: [String: String] = [:]
    private(set) var remotes: [Remote] = []
    private(set) var status = WorkingStatus()
    private(set) var worktrees: [Worktree] = []
    private(set) var worktreeInfo: [String: WorktreeInfo] = [:]
    /// Bumped whenever worktreeInfo changes (for views that aren't observing it directly).
    private(set) var worktreeInfoVersion = 0
    /// Per commit index: true when the commit is HEAD or one of its ancestors.
    /// GitKraken-style dimming of commits that aren't on the current branch.
    private(set) var headAncestry: [Bool] = []
    private(set) var stashes: [Stash] = []
    private(set) var operation: RepoOperation?
    private(set) var hasMoreCommits = false
    /// Bumped whenever history rows change, so the table knows to reload.
    private(set) var historyVersion = 0
    var commitLimit = 2000
    /// What `git log` found for the search field's `file:` / `change:` terms,
    /// over the whole history. Nil while the field has neither.
    private(set) var historySearch: HistorySearch?
    /// Bumped whenever the found commits change, so the table reloads.
    private(set) var historySearchVersion = 0

    // UI state shared across views
    var selection: HistorySelection? = .workingCopy
    var revealToken = 0
    var filterText = ""
    /// What the toolbar search holds on the Board and in Reviews (History uses filterText).
    var taskQuery = ""
    var reviewQuery = ""
    var busy: String?
    var alert: AlertItem?
    var confirmation: Confirmation?
    /// A failed git action shown in plain words (ProblemSheet).
    var problem: GitProblem?
    /// The last failure, also when it wasn't shown (sheets show it inline).
    var lastProblem: GitProblem?
    /// A stash applied with conflicts; it is kept until the user drops it.
    var stashConflict: Stash?
    /// Runs after the identity sheet saved a name and email (the commit that needed it).
    @ObservationIgnored var afterIdentity: (() async -> Void)?
    var sheet: SheetKind?
    var openDiff: DiffTarget?
    var showCommandLog = false
    /// The last git action Edit > Undo can take back (one level). Set by the
    /// actions in RepoActions, cleared by most other commands (see RepoUndo).
    var lastUndo: UndoRecord?
    /// History graph, task board or review list in the middle.
    var centerMode: CenterMode = .history
    /// Task or review shown in the right panel while on Board / Reviews.
    var coworkSelection: CoworkSelection?
    /// Shared tasks, reviews and comments for this repository.
    let cowork: CoworkStore
    /// Background `git fetch` (see RepoAutoFetch).
    let autoFetcher = RepoAutoFetch()
    /// Commit message being written. Shared by the commit box and the "// WIP" row.
    var draftSummary = ""
    var draftDetails = ""
    /// Shows another worktree of this repository: focuses its tab, else
    /// switches this window to it. Set by the window; nil without one.
    @ObservationIgnored var openWorktree: ((String) -> Void)?
    /// Bump to move keyboard focus to the commit summary field.
    var focusSummaryToken = 0
    /// Bumped on every refresh; open working-copy diffs reload on it.
    private(set) var refreshCount = 0
    private var loadingMore = false

    private var fingerprint = ""
    private var watcher: FileWatcher?
    private var watchedPaths: [String] = []
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    /// When the last pass of `refresh` started reading the repository.
    private var lastPassStart: Date?

    // File changes (see "File watching" below).
    /// The refresh a file change asked for, while it waits its turn.
    private var dueRefresh: Task<Void, Never>?
    /// When the last file change that needs a refresh arrived.
    private var changedAt = Date.distantPast
    /// When the last refresh for a file change started, and how long it took.
    private var lastWatchedRefresh: Date?
    private var lastWatchedDuration: TimeInterval = 0
    /// Paths git ignores, as `git check-ignore` said. `ignoredEpoch` counts
    /// how often they were forgotten, so a late answer isn't kept.
    private var ignoredPaths = IgnoredPaths()
    private var ignoredEpoch = 0
    /// Other worktrees whose change counts are due, and the task reading them.
    private var dueWorktrees: Set<String> = []
    private var worktreeInfoTask: Task<Void, Never>?
    /// False while this window's tab is behind another one (set by the window).
    private(set) var isShowing = true

    init(root: URL) {
        // Resolve symlinks (/tmp -> /private/tmp) so paths match what git reports.
        self.root = URL(fileURLWithPath: realPath(root.path))
        self.cowork = CoworkStore(root: self.root)
        autoFetcher.model = self
    }

    var name: String { mainWorktreePath.map { ($0 as NSString).lastPathComponent } ?? root.lastPathComponent }
    var mainWorktreePath: String? { worktrees.first(where: \.isMain)?.path }
    var currentBranch: String? { status.branch }
    var headSHA: String? { status.headOID }
    var localBranches: [Ref] { refs.filter { $0.kind == .localBranch } }
    var remoteBranches: [Ref] { refs.filter { $0.kind == .remoteBranch } }
    var tags: [Ref] { refs.filter { $0.kind == .tag } }
    var remoteNames: [String] { remotes.map(\.name) }

    // MARK: Loading

    func load() async {
        do {
            let out = try await git.run(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: root)
            let lines = out.split(separator: "\n").map(String.init)
            guard lines.count >= 2 else { throw GitError(command: "rev-parse", result: GitResult(stdout: out, stderr: "Not a git repository", exitCode: 1)) }
            gitDir = URL(fileURLWithPath: lines[0])
            commonDir = URL(fileURLWithPath: lines[1])
        } catch {
            loadError = error.localizedDescription
            return
        }
        await refresh()
        isLoaded = true
        // Clean: show the checked-out commit (where the history scrolls to),
        // not the newest commit of some other branch.
        selection = status.isClean ? (headSHA ?? commits.first?.id).map { .commit($0) } : .workingCopy
        // The window may have closed while loading; don't start anything then.
        guard !isStopped else { return }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshNow()
                if let self, Prefs.coworkAutoSync, (self.cowork.lastSync.map { Date().timeIntervalSince($0) > 30 } ?? true) { await self.syncCowork() }
                await self?.updateHostStatus()
            }
        }
        cowork.remote = await resolveCoworkRemote()
        updateKnownAuthors()
        await cowork.load()
        guard !isStopped else { return }
        startCoworkSync()
        autoFetcher.start()
        await updateHostStatus()
    }

    /// Called when the window closes: stops file watching, timers and observers.
    /// A cowork push already scheduled still finishes, so no edit stays local.
    func stopWatching() {
        isStopped = true
        watcher?.stop()
        watcher = nil
        coworkTimer?.cancel()
        coworkTimer = nil
        autoFetcher.stop()
        dueRefresh?.cancel()
        dueRefresh = nil
        worktreeInfoTask?.cancel()
        worktreeInfoTask = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// Pull requests and CI on the remote's host. Nil for a host of unknown kind.
    var hostStatus: HostStatus?

    /// True once the window closed (see stopWatching).
    private(set) var isStopped = false
    private var activationObserver: NSObjectProtocol?

    // MARK: Cowork

    private var coworkTimer: Task<Void, Never>?

    /// Syncs tasks/reviews now, then every minute while the app is in front and
    /// every 3 minutes in the background, so teammates' mentions and review
    /// requests still arrive as notifications. Each sync is one small fetch of a
    /// single ref.
    private func startCoworkSync() {
        coworkTimer?.cancel()
        coworkTimer = Task { [weak self] in
            await self?.syncCowork()
            var lastSync = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                let interval: TimeInterval = NSApp.isActive ? 60 : 180
                guard Prefs.coworkAutoSync, Date().timeIntervalSince(lastSync) >= interval else { continue }
                lastSync = Date()
                await self.syncCowork()
            }
        }
    }

    /// Remote for cowork sync: the same rule as `git cowork` (CoworkRemote),
    /// read from `git config cowork.remote`. A remote picked because it
    /// already has the team's tasks is written there, so the tool uses it too.
    func resolveCoworkRemote() async -> String? {
        let choice = await CoworkRemote.choose(root: root, git: AppGit())
        if let remote = choice.remote, choice.worthRemembering {
            _ = try? await git.run(CoworkRemote.rememberArgs(remote), in: root, logged: true)
        }
        return choice.remote
    }

    // MARK: Background fetch (RepoAutoFetch)

    var autoFetching: Bool { autoFetcher.running }
    var autoFetchPaused: String? { autoFetcher.paused }

    /// Records a fetch (or pull/push) the user ran, so the timer starts over
    /// and a sign-in pause ends once it worked.
    func noteRemoteAction(fetched: Bool, succeeded: Bool) {
        autoFetcher.note(fetched: fetched, succeeded: succeeded)
        if succeeded { Task { await updateHostStatus(force: true) } }
    }

    /// Waits up to 15 s for a running background fetch, then goes ahead anyway.
    func waitForAutoFetch() async {
        await autoFetcher.waitUntilIdle()
    }

    func syncCowork() async {
        cowork.remote = await resolveCoworkRemote()
        await cowork.sync()
        CoworkNotifier.shared.deliver(cowork.inbox, repo: mainWorktreePath ?? root.path, repoName: name)
    }

    private func updateKnownAuthors() {
        var seen = Set<String>()
        var authors: [(name: String, email: String)] = []
        for c in commits where seen.insert(c.authorEmail.lowercased()).inserted {
            authors.append((c.authorName, c.authorEmail))
        }
        cowork.knownAuthors = authors
    }

    /// Reloads everything that may have changed. Calls made while a refresh
    /// is running are merged into one more pass.
    /// When this returns, a full pass has run that started after the call
    /// (callers read status/refs right after a git command).
    func refresh() async {
        refreshPending = true
        if let running = refreshTask { await running.value; return }
        let task = Task { @MainActor in
            while refreshPending {
                refreshPending = false
                await refreshOnce()
            }
            refreshTask = nil   // same synchronous step as the last check, so no call slips in between
        }
        refreshTask = task
        await task.value
    }

    private func refreshOnce() async {
        defer { refreshCount += 1 }
        lastPassStart = Date()
        // --no-optional-locks: this status runs by itself in the background. Without
        // it git rewrites .git/index when it can, which makes a commit or `git add`
        // running at that moment (in a terminal, by an agent) fail on index.lock,
        // and the write comes back here as a change to refresh for.
        async let statusOut = git.tryRun(["--no-optional-locks", "status", "--porcelain=v2", "-z", "--branch", "-uall"], in: root)
        async let refsOut = git.tryRun(["for-each-ref", Parsers.refFormat, "refs/heads", "refs/remotes", "refs/tags"], in: root)
        async let stashOut = git.tryRun(["stash", "list", Parsers.stashFormat], in: root)
        async let worktreeOut = git.tryRun(["worktree", "list", "--porcelain"], in: root)
        async let remoteOut = git.tryRun(["remote", "-v"], in: root)

        let (s, r, st, wt, rem) = await (statusOut ?? "", refsOut ?? "", stashOut ?? "", worktreeOut ?? "", remoteOut ?? "")

        let newStatus = Parsers.parseStatus(s)
        if newStatus != status { status = newStatus }
        let newOperation = detectOperation()
        if newOperation != operation { operation = newOperation }

        let newRemotes = Parsers.parseRemotes(rem)
        if newRemotes != remotes { remotes = newRemotes }

        let fp = r + "|" + (newStatus.headOID ?? "") + "|" + st + "|\(commitLimit)"
        if fp != fingerprint {
            fingerprint = fp
            let list = Parsers.parseRefs(r)
            refs = list.refs
            remoteDefaults = list.remoteDefaults
            stashes = Parsers.parseStashes(st)
            await loadHistory()
            leaveMissingStash()
        }

        let newWorktrees = Parsers.parseWorktrees(wt)
        if newWorktrees != worktrees {
            worktrees = newWorktrees
            // Forget removed worktrees, so the graph drops their "// WIP" rows.
            let kept = worktreeInfo.filter { info in newWorktrees.contains { $0.path == info.key } }
            if kept.count != worktreeInfo.count {
                worktreeInfo = kept
                worktreeInfoVersion += 1
            }
            restartWatcher()
            await refreshWorktreeInfo(paths: worktrees.map(\.path))
        } else {
            let info = WorktreeInfo(status)
            if worktreeInfo[root.path] != info {
                worktreeInfo[root.path] = info
                worktreeInfoVersion += 1
            }
        }
    }

    private func loadHistory() async {
        guard status.headOID != nil || !refs.isEmpty else {
            commits = []; graph = []; commitIndex = [:]; refsByCommit = [:]; headAncestry = []
            historyVersion += 1
            return
        }
        var args = ["log", "--date-order", "-n", "\(commitLimit)", Parsers.logFormat, "--branches", "--remotes", "--tags"]
        if status.headOID != nil { args.append("HEAD") }
        args.append("--")
        let out = await git.tryRun(args, in: root) ?? ""
        let (newCommits, newGraph) = await Task.detached(priority: .userInitiated) {
            let c = Parsers.parseLog(out)
            return (c, GraphLayout.layout(c))
        }.value

        var index: [String: Int] = [:]
        index.reserveCapacity(newCommits.count)
        for (i, c) in newCommits.enumerated() { index[c.id] = i }

        var byCommit: [String: [Ref]] = [:]
        for ref in refs { byCommit[ref.target, default: []].append(ref) }
        for key in byCommit.keys {
            byCommit[key]?.sort { a, b in
                if a.isHead != b.isHead { return a.isHead }
                if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
                return a.name < b.name
            }
        }

        // Mark HEAD and everything reachable from it through parents.
        var ancestry = [Bool](repeating: false, count: newCommits.count)
        if let head = status.headOID, let start = index[head] {
            var stack = [start]
            while let i = stack.popLast() {
                if ancestry[i] { continue }
                ancestry[i] = true
                for p in newCommits[i].parents {
                    if let j = index[p], !ancestry[j] { stack.append(j) }
                }
            }
        }

        commits = newCommits
        graph = newGraph
        headAncestry = ancestry
        commitIndex = index
        refsByCommit = byCommit
        hasMoreCommits = newCommits.count >= commitLimit
        historyVersion += 1
    }

    // MARK: History search

    /// Most commits a `file:` / `change:` search shows (the newest ones).
    static let historySearchLimit = 2000

    /// Runs the search field's `file:` / `change:` terms through `git log`,
    /// over every branch and the whole history, not just the loaded commits.
    /// The history view calls this whenever the terms or the history change;
    /// a call that is overtaken is cancelled, which also stops its git.
    func searchHistory(_ query: CommitQuery) async {
        guard let key = query.historyKey else {
            // No reload needed: the changed search text already rebuilt the list.
            if historySearch != nil { historySearch = nil }
            return
        }
        // The last result stays on screen until the new one is there.
        historySearch = HistorySearch(key: key, commits: historySearch?.commits ?? [], running: true)
        // Still typing: wait for a pause before starting git.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        var args = ["log", "--date-order", "-n", "\(Self.historySearchLimit)", Parsers.logFormat]
        args += query.logOptions
        args += ["--branches", "--remotes", "--tags"]
        if status.headOID != nil { args.append("HEAD") }
        args.append("--")
        args += query.logPathspecs
        let out = await git.tryRun(args, in: root, cancellable: true)
        guard !Task.isCancelled else { return }
        let found = await Task.detached(priority: .userInitiated) { Parsers.parseLog(out ?? "") }.value
        guard !Task.isCancelled else { return }
        historySearch = HistorySearch(key: key, commits: found, running: false)
        historySearchVersion += 1
    }

    /// The stash on screen was popped or deleted: show the changes it left
    /// behind, or the checked-out commit.
    private func leaveMissingStash() {
        guard case .stash(let sha) = selection, !stashes.contains(where: { $0.sha == sha }) else { return }
        if case .commit = openDiff { openDiff = nil }   // a file of that stash
        selection = status.isClean ? (headSHA ?? commits.first?.id).map { .commit($0) } : .workingCopy
    }

    func loadMoreCommits() {
        // Only when the current limit has actually loaded; a refresh already
        // in flight must not let the limit grow several times.
        guard hasMoreCommits, !loadingMore, commits.count >= commitLimit else { return }
        loadingMore = true
        commitLimit += 3000
        Task {
            await refresh()
            loadingMore = false
        }
    }

    private func detectOperation() -> RepoOperation? {
        guard let dir = gitDir else { return nil }
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }

    private func refreshWorktreeInfo(paths: [String]) async {
        await withTaskGroup(of: (String, WorktreeInfo?).self) { group in
            for path in paths {
                group.addTask { [git] in
                    guard let out = await git.tryRun(["--no-optional-locks", "status", "--porcelain=v2", "-z", "--branch"], in: URL(fileURLWithPath: path)) else {
                        return (path, nil)
                    }
                    return (path, WorktreeInfo(Parsers.parseStatus(out)))
                }
            }
            // Collect first, then assign once: one view update instead of one per worktree.
            var updated = worktreeInfo
            for await (path, info) in group { updated[path] = info }
            if updated != worktreeInfo {
                worktreeInfo = updated
                worktreeInfoVersion += 1
            }
        }
    }

    // MARK: File watching

    private func restartWatcher() {
        // A refresh still running when the window closed must not start watching again.
        guard !isStopped else { return }
        var paths = [root.path]
        if let c = commonDir?.path { paths.append(c) }
        paths += worktrees.map(\.path).filter { !$0.isEmpty }
        // Drop duplicates and paths nested inside another watched path.
        let unique = Array(Set(paths)).sorted()
        let roots = unique.filter { p in !unique.contains { $0 != p && p.hasPrefix($0 + "/") } }
        guard roots != watchedPaths else { return }
        watchedPaths = roots
        forgetIgnoredPaths()
        watcher?.stop()
        watcher = FileWatcher(paths: roots) { [weak self] changed in
            MainActor.assumeIsolated { self?.handleFileEvents(changed) }
        }
    }

    /// Sorts a batch of changed paths. git's own files mean a refresh. Files
    /// in a worktree do only when git doesn't ignore them: a build writing
    /// thousands of files into an ignored folder then costs nothing.
    private func handleFileEvents(_ paths: [String]) {
        // Deepest first: a worktree can sit inside another one's folder
        // (.claude/worktrees/…), and its files are its own.
        let roots = Set(worktrees.map(\.path).filter { !$0.isEmpty } + [root.path]).sorted { $0.count > $1.count }
        var gitChanged = false
        var rulesChanged = false
        var coworkChanged = false
        var files: [String: [String]] = [:]   // by worktree
        for p in paths {
            if p.contains("/.git/objects/") || p.hasSuffix(".lock") || p.contains("/.git/logs/") { continue }
            // Written by every fetch; nothing we show depends on it.
            if p.hasSuffix("/FETCH_HEAD") { continue }
            // Tasks and reviews (moved by this or another window): no graph refresh needed.
            if p.contains("/refs/cowork/") { coworkChanged = true; continue }
            if let git = commonDir?.path, p == git || p.hasPrefix(git + "/") { gitChanged = true; continue }
            guard let wt = roots.first(where: { p == $0 || p.hasPrefix($0 + "/") }) else { gitChanged = true; continue }
            if p.hasSuffix("/.gitignore") { rulesChanged = true }
            files[wt, default: []].append(p)
        }
        // The index or the ignore rules moved: what git said under the old ones is void.
        if gitChanged || rulesChanged { forgetIgnoredPaths() }
        if coworkChanged, cowork.loaded {
            Task { await cowork.reload() }
        }
        if gitChanged {
            files[root.path] = nil   // the refresh reads this worktree's files anyway
            scheduleRefresh()
        }
        if !files.isEmpty {
            Task { await sortOut(files) }
        }
    }

    /// Changed files per worktree: a refresh for this one, new counts for the
    /// "// WIP" row of another one, nothing when git ignores them all.
    private func sortOut(_ files: [String: [String]]) async {
        for (wt, paths) in files {
            guard await hasRelevantChange(paths, in: wt), !isStopped else { continue }
            if wt == root.path { scheduleRefresh() } else { scheduleWorktreeInfo(wt) }
        }
    }

    /// False when git ignores every one of `paths`. Asks `git check-ignore`
    /// about paths it hasn't seen yet and remembers the answer.
    private func hasRelevantChange(_ paths: [String], in wt: String) async -> Bool {
        var unknown: [String] = []
        for p in paths {
            switch p == wt ? .relevant : ignoredPaths.answer(for: p) {
            case .relevant: return true
            case .ignored: continue
            case .unknown: unknown.append(p)
            }
        }
        guard !unknown.isEmpty else { return false }
        // A sample is enough: the folders above it are asked about too, and
        // what is still unknown afterwards counts as a change.
        let asked = IgnoredPaths.questions(for: Array(unknown.prefix(200)), under: wt)
        let epoch = ignoredEpoch
        let reply = await git.executeData(["check-ignore", "-z", "--stdin"], in: URL(fileURLWithPath: wt),
                                          input: Data((asked.joined(separator: "\0") + "\0").utf8))
        // 0: some are ignored, 1: none is. Anything else: can't tell, so refresh.
        guard reply.exitCode == 0 || reply.exitCode == 1 else { return true }
        var learned = ignoredPaths
        learned.learn(asked: asked, ignored: reply.text.split(separator: "\0").map(String.init))
        if epoch == ignoredEpoch { ignoredPaths = learned }   // else the rules changed meanwhile
        return unknown.contains { learned.answer(for: $0) != .ignored }
    }

    private func forgetIgnoredPaths() {
        ignoredEpoch += 1
        if !ignoredPaths.isEmpty { ignoredPaths.forget() }
    }

    /// A file change asks for a refresh. One change shows after a short
    /// settle time; while changes keep coming, RefreshPacing spaces the
    /// refreshes out. The one that is waiting covers every change until it runs.
    private func scheduleRefresh() {
        changedAt = Date()
        guard dueRefresh == nil, !isStopped else { return }
        let wait = RefreshPacing.wait(sinceLast: lastWatchedRefresh.map { Date().timeIntervalSince($0) },
                                      lastDuration: lastWatchedDuration, watched: isShowing && NSApp.isActive)
        dueRefresh = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            dueRefresh = nil   // a change from here on asks for the next one
            // An action's own refresh has read the repository since: nothing new to see.
            if let lastPassStart, lastPassStart >= changedAt { return }
            let start = Date()
            lastWatchedRefresh = start
            await refresh()
            lastWatchedDuration = Date().timeIntervalSince(start)
        }
    }

    /// Refreshes right away, also for changes that were waiting their turn,
    /// and looks at the ignore rules again. For when the user comes back.
    func refreshNow() async {
        dueRefresh?.cancel()
        dueRefresh = nil
        forgetIgnoredPaths()
        await refresh()
    }

    /// The window's tab came to the front or went behind another one. Behind,
    /// changes that keep coming are read less often; in front again, what
    /// was waiting shows at once.
    func setShowing(_ showing: Bool) {
        guard showing != isShowing else { return }
        isShowing = showing
        if showing, dueRefresh != nil { Task { await refreshNow() } }
    }

    /// Another worktree's files changed: read its counts, once for all the
    /// changes that arrive while it waits. Nobody acts on these counts, so
    /// there is no hurry.
    private func scheduleWorktreeInfo(_ path: String) {
        dueWorktrees.insert(path)
        guard worktreeInfoTask == nil, !isStopped else { return }
        worktreeInfoTask = Task {
            while !Task.isCancelled, !dueWorktrees.isEmpty {
                let watched = isShowing && NSApp.isActive
                try? await Task.sleep(for: .seconds(watched ? RefreshPacing.watchedGap : RefreshPacing.unwatchedGap))
                guard !Task.isCancelled else { break }
                let paths = Array(dueWorktrees)
                dueWorktrees = []
                await refreshWorktreeInfo(paths: paths)
            }
            worktreeInfoTask = nil
        }
    }

    // MARK: Lookups

    /// A loaded commit, or one a `file:` / `change:` search found further back.
    func commit(_ sha: String) -> Commit? {
        commitIndex[sha].map { commits[$0] } ?? historySearch?.commits.first { $0.id == sha }
    }

    func reveal(_ sha: String) {
        selection = .commit(sha)
        revealToken += 1
    }

    /// The current branch's upstream remote, else origin, else the first remote.
    var defaultRemote: String? {
        BranchLookup.defaultRemote(upstream: status.upstream, remotes: remoteNames)
    }

    /// Web links for a remote. The host's kind comes from Settings, else from
    /// a signed-in account on that host (self-hosted servers), else its name.
    func links(for remoteName: String?) -> RemoteLinks? {
        guard let name = remoteName ?? defaultRemote,
              let remote = remotes.first(where: { $0.name == name }) else { return nil }
        var kinds: [String: HostKind] = [:]
        for account in AccountStore.shared.accounts {
            let host = account.host.split(separator: ":").first.map(String.init) ?? account.host
            kinds[host] = account.kind
        }
        let overrides = kinds.merging(RemoteLinks.parseOverrides(Prefs.hostOverrides)) { _, setting in setting }
        return RemoteLinks(remoteURL: remote.url, overrides: overrides)
    }

    func defaultBranch(remote: String?) -> String? {
        remoteDefaults[remote ?? defaultRemote ?? "origin"]
    }

    // MARK: Details and diffs

    func commitDetail(_ sha: String) async -> CommitDetail? {
        guard let out = await git.tryRun(["show", "-s", Parsers.detailFormat, sha], in: root) else { return nil }
        return Parsers.parseCommitDetail(out)
    }

    func changedFiles(_ detail: CommitDetail) async -> [FileChange] {
        var args = ["diff-tree", "-r", "-z", "-M", "--name-status", "--no-commit-id"]
        if let p = detail.parents.first { args += [p, detail.id] } else { args += ["--root", detail.id] }
        return Parsers.parseNameStatus(await git.tryRun(args, in: root) ?? "")
    }

}
