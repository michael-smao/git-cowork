import Foundation
import GitCoworkCore
import Observation

/// The saved workspaces (Settings key `workspaces`). Every tab showing one
/// reads it from here, so a change shows in all of them.
@MainActor @Observable
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    private(set) var all: [Workspace] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Prefs.Key.workspaces),
           let saved = try? JSONDecoder().decode([Workspace].self, from: data) {
            all = saved
        }
    }

    /// By name, for menus and the welcome screen.
    var sorted: [Workspace] {
        all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func workspace(_ id: String?) -> Workspace? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The workspace made from scanning `folder`, if there is one.
    func workspace(scanRoot folder: String) -> Workspace? {
        let real = realPath(folder)
        return all.first { $0.scanRoot.map(realPath) == real }
    }

    @discardableResult
    func create(name: String, repos: [String], scanRoot: String? = nil, scanDepth: Int? = nil) -> Workspace {
        let ws = Workspace(name: name, repos: repos, scanRoot: scanRoot, scanDepth: scanDepth)
        all.append(ws)
        save()
        return ws
    }

    func update(_ id: String, _ change: (inout Workspace) -> Void) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        var ws = all[i]
        change(&ws)
        guard ws != all[i] else { return }
        all[i] = ws
        save()
    }

    func delete(_ id: String) {
        all.removeAll { $0.id == id }
        UserDefaults.standard.removeObject(forKey: Prefs.Key.workspaceCollapsed(id))
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: Prefs.Key.workspaces)
    }
}

/// Reading workspaces' folders from disk, off the main thread.
enum WorkspaceDisk {
    /// The repositories under `root` (RepoScan), as real paths. A linked
    /// worktree found next to its repository is left out: the tree shows it
    /// below the repository.
    static func scan(_ root: String, depth: Int) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let found = RepoScan.find(in: realPath(root), depth: depth, list: list).map(realPath)
            return RepoScan.withoutLinkedWorktrees(found, mainWorktree: mainWorktree(of:))
        }.value
    }

    /// The main worktree of the linked worktree in `folder`, read from its
    /// `.git` file without running git. Nil for a main worktree, whose `.git`
    /// is a folder.
    static func mainWorktree(of folder: String) -> String? {
        let gitFile = (folder as NSString).appendingPathComponent(".git")
        guard let contents = try? String(contentsOfFile: gitFile, encoding: .utf8),
              let main = WorktreeLink.mainWorktree(gitFile: contents, worktree: folder) else { return nil }
        return realPath(main)
    }

    /// Each repository's linked worktrees that still exist, read from
    /// `.git/worktrees/*/gitdir` without running git.
    static func worktrees(of repos: [String]) async -> [String: [String]] {
        await Task.detached(priority: .utility) {
            var result: [String: [String]] = [:]
            for repo in repos {
                let found = linkedWorktrees(of: repo)
                if !found.isEmpty { result[repo] = found }
            }
            return result
        }.value
    }

    /// Uncommitted changes and commits ahead/behind of each folder, from
    /// `git status` (no network: ahead/behind is as of the last fetch).
    /// A few at a time, so a large workspace doesn't start dozens of gits at once.
    static func status(of paths: [String]) async -> [String: WorktreeInfo] {
        let git = GitRunner.shared
        return await withTaskGroup(of: (String, WorktreeInfo?).self) { group in
            var pending = paths[...]
            func next() {
                guard let path = pending.popFirst() else { return }
                group.addTask {
                    let out = await git.tryRun(["status", "--porcelain=v2", "-z", "--branch"], in: URL(fileURLWithPath: path))
                    return (path, out.map { WorktreeInfo(Parsers.parseStatus($0)) })
                }
            }
            for _ in 0..<statusParallel { next() }
            var result: [String: WorktreeInfo] = [:]
            for await (path, info) in group {
                if let info { result[path] = info }
                next()
            }
            return result
        }
    }

    private static let statusParallel = 6

    static func exists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func list(_ dir: String) -> [RepoScan.Entry]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir),
                                                                       includingPropertiesForKeys: keys) else { return nil }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return RepoScan.Entry(name: url.lastPathComponent, isDirectory: values?.isDirectory ?? false,
                                  isSymlink: values?.isSymbolicLink ?? false)
        }
    }

    private static func linkedWorktrees(of repo: String) -> [String] {
        let admin = (repo as NSString).appendingPathComponent(".git/worktrees")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: admin) else { return [] }
        return names.compactMap { name in
            let dir = (admin as NSString).appendingPathComponent(name)
            guard let contents = try? String(contentsOfFile: (dir as NSString).appendingPathComponent("gitdir"), encoding: .utf8),
                  let folder = WorktreeLink.worktreeFolder(gitdirFile: contents, adminDir: dir),
                  exists(folder) else { return nil }
            return realPath(folder)
        }
    }
}
