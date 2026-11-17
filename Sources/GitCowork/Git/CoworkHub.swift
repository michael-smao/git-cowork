import CoworkKit
import Foundation
import GitCoworkCore
import Observation

/// Tasks shared between repositories (CoworkTask.repos). Each repository's
/// board shows its own `refs/cowork/main`; a shared task is stored in every
/// repository it belongs to. This keeps those copies in step (CoworkMirror)
/// across the repositories open here, and the recent ones a shared task
/// names: after any change to a shared task, and when a repository opens.
@MainActor @Observable
final class CoworkHub {
    static let shared = CoworkHub()

    /// A repository on this Mac that tasks can be shared with.
    struct KnownRepo: Hashable, Identifiable {
        let id: String       // RepoID
        let path: String     // main worktree
        var name: String { RepoID.name(id) }
    }

    /// Open and recent repositories with a remote, by RepoID; open ones win.
    private(set) var known: [KnownRepo] = []

    /// Recent repositories that aren't open: their tasks, loaded when a shared task needs them.
    @ObservationIgnored private var closedStores: [String: CoworkStore] = [:]
    @ObservationIgnored private var closedSynced: [String: Date] = [:]
    /// path -> RepoID (nil: no remote), so recents are asked once.
    @ObservationIgnored private var identities: [String: String?] = [:]
    @ObservationIgnored private var due: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false

    private init() {}

    // MARK: Triggers

    /// A shared task changed somewhere: copy it to the others soon.
    func changed() {
        due?.cancel()
        due = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await reconcile()
        }
    }

    /// A repository opened or closed: read it in, and refresh the list.
    func repositoryOpened() {
        Task { await refreshKnown() }
        changed()
    }

    // MARK: Known repositories

    private var openStores: [(id: String, store: CoworkStore, path: String)] {
        LiveRepos.shared.models.compactMap { m in
            guard m.cowork.loaded, let id = m.cowork.repoID?.lowercased() else { return nil }
            return (id, m.cowork, m.mainWorktreePath ?? m.root.path)
        }
    }

    /// Repositories to offer when adding one to a task: open ones, tabs
    /// that haven't loaded yet (restored in the background), then recent ones.
    func refreshKnown() async {
        var byID: [String: KnownRepo] = [:]
        for o in openStores where byID[o.id] == nil { byID[o.id] = KnownRepo(id: o.id, path: o.path) }
        let tabs = OpenSession.openTargets.compactMap(\.path).sorted()
        for path in tabs + Prefs.visibleRecents {
            if identities[path] == nil { identities[path] = .some(await Self.identity(of: path)) }
            if let id = (identities[path] ?? nil)?.lowercased(), byID[id] == nil { byID[id] = KnownRepo(id: id, path: path) }
        }
        let list = byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if list != known { known = list }
    }

    /// RepoID of a folder's cowork remote, read without opening it.
    private static func identity(of path: String) async -> String? {
        let root = URL(fileURLWithPath: path)
        guard let remote = await CoworkRemote.choose(root: root, git: AppGit()).remote,
              let url = await GitRunner.shared.tryLine(["remote", "get-url", "--", remote], in: root) else { return nil }
        return RepoID.of(remoteURL: url)
    }

    // MARK: Keeping copies in step

    func reconcile() async {
        guard !running else { again = true; return }
        running = true
        defer { running = false }
        // Writing a copy changes that store, which asks again; that round
        // finds nothing to do. A few rounds at most, whatever happens.
        for _ in 0..<3 {
            again = false
            await reconcileOnce()
            if !again { break }
        }
    }

    private func reconcileOnce() async {
        var byID: [String: CoworkStore] = [:]
        for o in openStores where byID[o.id] == nil { byID[o.id] = o.store }
        // Repositories that shared tasks here name, but aren't open.
        var named = Set<String>()
        for store in byID.values {
            for t in store.tasks { named.formUnion(t.repos.map { $0.lowercased() }) }
        }
        if named.contains(where: { byID[$0] == nil }) { await refreshKnown() }
        for id in named where byID[id] == nil {
            if let store = await closedStore(for: id) { byID[id] = store }
        }
        guard byID.count > 1 else { return }
        let me = byID.values.first { !$0.me.email.isEmpty }?.me.email ?? ""
        let repos = byID.map { CoworkMirror.Repo(id: $0.key, snapshot: $0.value.snapshot) }
        let changes = CoworkMirror.changes(repos, me: me)
        for (id, files) in changes.sorted(by: { $0.key < $1.key }) {
            guard let store = byID[id] else { continue }
            await store.write(CoworkEdit.mirror(files))
        }
    }

    /// A recent repository that isn't open, loaded and fetched (at most every few minutes).
    private func closedStore(for id: String) async -> CoworkStore? {
        let id = id.lowercased()
        guard let repo = known.first(where: { $0.id == id }),
              !openStores.contains(where: { $0.id == id }) else { return nil }
        let store: CoworkStore
        if let existing = closedStores[repo.path] {
            store = existing
        } else {
            store = CoworkStore(root: URL(fileURLWithPath: repo.path))
            store.remote = await CoworkRemote.choose(root: store.root, git: AppGit()).remote
            store.repoID = id
            await store.load()
            closedStores[repo.path] = store
        }
        if Prefs.coworkAutoSync, store.remote != nil, (closedSynced[repo.path].map { Date().timeIntervalSince($0) > 180 } ?? true) {
            closedSynced[repo.path] = Date()
            await store.sync()
        }
        return store
    }
}
