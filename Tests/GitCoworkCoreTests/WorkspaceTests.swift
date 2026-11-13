import Foundation
import Testing
@testable import GitCoworkCore

@Suite struct WorkspaceTests {
    @Test func addsEachRepositoryOnce() {
        var ws = Workspace(name: "Acme", repos: ["/a", "/b", "/a"])
        #expect(ws.repos == ["/a", "/b"])
        #expect(ws.add(["/b", "/c"]) == 1)
        #expect(ws.repos == ["/a", "/b", "/c"])
    }

    @Test func startsWithTheLastRepositoryShown() {
        var ws = Workspace(name: "Acme", repos: ["/a", "/b"])
        #expect(ws.startRepo == "/a")
        ws.lastRepo = "/b"
        #expect(ws.startRepo == "/b")
        ws.remove("/b")
        #expect(ws.lastRepo == nil)
        #expect(ws.startRepo == "/a")
        ws.lastRepo = "/gone"
        #expect(ws.startRepo == "/a")
    }

    /// Removed by hand: scanning again leaves it out, adding it by hand brings it back.
    @Test func scanningAgainSkipsRemovedRepositories() {
        var ws = Workspace(name: "Acme", repos: ["/a", "/b"])
        ws.remove("/b")
        #expect(ws.removed == ["/b"])
        #expect(ws.addScanned(["/a", "/b", "/c"]) == 1)
        #expect(ws.repos == ["/a", "/c"])
        #expect(ws.add(["/b"]) == 1)
        #expect(ws.repos == ["/a", "/c", "/b"])
        #expect(ws.removed == nil)
        ws.remove("/gone")
        #expect(ws.removed == nil)
    }

    /// Saved before `removed` existed.
    @Test func readsOlderWorkspaces() throws {
        let old = #"{"id":"W","name":"Acme","repos":["/a"]}"#.data(using: .utf8)!
        let ws = try JSONDecoder().decode(Workspace.self, from: old)
        #expect(ws.repos == ["/a"])
        #expect(ws.removed == nil)
    }

    @Test func roundTripsAsJSON() throws {
        let ws = Workspace(name: "Acme", repos: ["/a"], scanRoot: "/", scanDepth: 2, lastRepo: "/a")
        let back = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        #expect(back == ws)
    }
}

@Suite struct TabTargetTests {
    @Test func roundTrips() throws {
        for target in [TabTarget(path: "/a"), TabTarget(workspace: "W"), TabTarget(path: "/a", workspace: "W")] {
            let back = try JSONDecoder().decode(TabTarget.self, from: JSONEncoder().encode(target))
            #expect(back == target)
        }
    }

    /// Windows macOS saved before workspaces existed hold just the path.
    @Test func readsAPlainPath() throws {
        let old = try JSONEncoder().encode("/Users/me/app")
        #expect(try JSONDecoder().decode(TabTarget.self, from: old) == TabTarget(path: "/Users/me/app"))
    }

    @Test func emptyWhenNothingIsShown() {
        #expect(TabTarget().isEmpty)
        #expect(!TabTarget(workspace: "W").isEmpty)
    }

    @Test func savedTabsKeepTheirWorkspaces() {
        let tabs = [TabTarget(path: "/a", workspace: "W"), TabTarget(workspace: "V"), TabTarget(path: "/b"), TabTarget(path: "/a")]
        #expect(SessionRestore.uniquePaths(tabs) == ["/a", "/b"])
        let saved = SessionRestore.savedTabs(tabs: tabs, selectedTab: tabs[1], paths: ["/a", "/b"], selectedPath: "/a")
        #expect(saved.tabs == tabs)
        #expect(saved.selected == tabs[1])
    }

    /// An older version (paths only) ran after this one: its tabs win.
    @Test func pathsSavedByAnOlderVersionWin() {
        let stale = [TabTarget(path: "/a", workspace: "W")]
        let saved = SessionRestore.savedTabs(tabs: stale, selectedTab: stale[0], paths: ["/x", "/y"], selectedPath: "/y")
        #expect(saved.tabs == [TabTarget(path: "/x"), TabTarget(path: "/y")])
        #expect(saved.selected == TabTarget(path: "/y"))
    }

    /// First launch after the update: only paths are there.
    @Test func pathsFromBeforeWorkspaces() {
        let saved = SessionRestore.savedTabs(tabs: nil, selectedTab: nil, paths: ["/x"], selectedPath: "/x")
        #expect(saved.tabs == [TabTarget(path: "/x")])
        #expect(saved.selected == TabTarget(path: "/x"))
    }

    @Test func restoresWorkspaceTabsBesideTheSameRepository() {
        let plain = TabTarget(path: "/a"), inWorkspace = TabTarget(path: "/a", workspace: "W")
        let p = SessionRestore.plan(saved: [plain, inWorkspace, plain], selected: inWorkspace, commandLine: [],
                                    alreadyOpen: [], exists: { _ in true })
        #expect(p == .init(open: [plain, inWorkspace], select: inWorkspace))
    }
}

@Suite struct RepoScanTests {
    /// A fake disk: folder path → entries. Names ending in "/" are folders,
    /// "@" marks a symlink to a folder.
    private func disk(_ layout: [String: [String]]) -> (String) -> [RepoScan.Entry]? {
        { dir in
            layout[dir]?.map { name in
                if name.hasSuffix("@") { return RepoScan.Entry(name: String(name.dropLast()), isDirectory: true, isSymlink: true) }
                if name.hasSuffix("/") { return RepoScan.Entry(name: String(name.dropLast()), isDirectory: true) }
                return RepoScan.Entry(name: name, isDirectory: false)
            }
        }
    }

    private let layout: [String: [String]] = [
        "/w": ["b/", "a/", "notes.txt", ".hidden/", "node_modules/", "deep/", "link@", "wt/"],
        "/w/a": [".git/", "src/"],
        "/w/a/src": ["inner/"],
        "/w/a/src/inner": [".git/"],
        "/w/b": [".git/"],
        "/w/.hidden": [".git/"],
        "/w/node_modules": [".git/"],
        "/w/link": [".git/"],
        "/w/wt": [".git"],
        "/w/deep": ["x/"],
        "/w/deep/x": [".git/"],
    ]

    @Test func depthOneFindsDirectSubfolders() {
        #expect(RepoScan.find(in: "/w", depth: 1, list: disk(layout)) == ["/w/a", "/w/b", "/w/wt"])
    }

    @Test func deeperFindsMoreButNeverInsideARepository() {
        #expect(RepoScan.find(in: "/w/", depth: 2, list: disk(layout)) == ["/w/a", "/w/b", "/w/deep/x", "/w/wt"])
        #expect(RepoScan.find(in: "/w", depth: 5, list: disk(layout)) == ["/w/a", "/w/b", "/w/deep/x", "/w/wt"])
    }

    @Test func theChosenFolderCanBeARepository() {
        #expect(RepoScan.find(in: "/w/b", depth: 1, list: disk(layout)) == ["/w/b"])
    }

    @Test func depthIsKeptInRange() {
        #expect(RepoScan.find(in: "/w", depth: 0, list: disk(layout)) == RepoScan.find(in: "/w", depth: 1, list: disk(layout)))
        #expect(RepoScan.find(in: "/w", depth: 99, list: disk(layout)) == RepoScan.find(in: "/w", depth: 5, list: disk(layout)))
    }

    @Test func unreadableFolderFindsNothing() {
        #expect(RepoScan.find(in: "/nope", depth: 3, list: disk(layout)).isEmpty)
    }

    /// git-cowork puts a new worktree next to its repository ("app-fix" beside
    /// "app"), so a scan finds both. The tree shows the worktree below the
    /// repository; it gets no entry of its own.
    @Test func leavesOutWorktreesOfFoundRepositories() {
        let mains = ["/w/app-fix": "/w/app", "/w/lone": "/elsewhere/main"]
        let found = ["/w/app", "/w/app-fix", "/w/lib", "/w/lone"]
        #expect(RepoScan.withoutLinkedWorktrees(found) { mains[$0] } == ["/w/app", "/w/lib", "/w/lone"])
        // The worktree's repository is somewhere else, but already in the workspace.
        #expect(RepoScan.withoutLinkedWorktrees(found, besides: ["/elsewhere/main"]) { mains[$0] } == ["/w/app", "/w/lib"])
        // Found before its repository: the order of the rest stays.
        #expect(RepoScan.withoutLinkedWorktrees(["/w/a-fix", "/w/b", "/w/a"]) { $0 == "/w/a-fix" ? "/w/a" : nil } == ["/w/b", "/w/a"])
        #expect(RepoScan.withoutLinkedWorktrees(found) { _ in nil } == found)
    }

    /// The real disk, the way the app lists folders.
    @Test func findsRepositoriesOnDisk() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }
        for dir in ["one/.git", "group/two/.git", "plain/src"] {
            try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
        }
        let list: (String) -> [RepoScan.Entry]? = { dir in
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
            return names.map { name in
                let path = dir + "/" + name
                let attrs = try? fm.attributesOfItem(atPath: path)
                let type = attrs?[.type] as? FileAttributeType
                return RepoScan.Entry(name: name, isDirectory: type == .typeDirectory, isSymlink: type == .typeSymbolicLink)
            }
        }
        #expect(RepoScan.find(in: root, depth: 1, list: list) == [root + "/one"])
        #expect(RepoScan.find(in: root, depth: 2, list: list) == [root + "/group/two", root + "/one"])
    }
}

@Suite struct WorkspaceTreeTests {
    @Test func baseIsTheSharedParent() {
        #expect(WorkspaceTree.base(of: ["/w/a", "/w/b"]) == "/w")
        #expect(WorkspaceTree.base(of: ["/w/x/a", "/w/y/b"]) == "/w")
        #expect(WorkspaceTree.base(of: ["/w/a"]) == "/w")
        #expect(WorkspaceTree.base(of: ["/a", "/b"]) == "/")
        #expect(WorkspaceTree.base(of: []) == "/")
    }

    @Test func foldersFirstThenRepositoriesByName() {
        let tree = WorkspaceTree.build(repos: ["/w/zeta", "/w/apps/web", "/w/Alpha", "/w/apps/api", "/w/item10", "/w/item2"])
        #expect(tree.map(\.name) == ["apps", "Alpha", "item2", "item10", "zeta"])
        #expect(tree.map(\.kind) == [.folder, .repo, .repo, .repo, .repo])
        #expect(tree[0].id == "/w/apps")
        #expect(tree[0].children.map(\.id) == ["/w/apps/api", "/w/apps/web"])
    }

    @Test func mergesFoldersWithASingleSubfolder() {
        let tree = WorkspaceTree.build(repos: ["/w/clients/acme/shop", "/w/clients/acme/admin", "/w/tools"])
        #expect(tree.map(\.name) == ["clients/acme", "tools"])
        #expect(tree[0].id == "/w/clients/acme")
        #expect(tree[0].children.map(\.name) == ["admin", "shop"])
    }

    @Test func worktreesHangBelowTheirRepository() {
        let tree = WorkspaceTree.build(repos: ["/w/app", "/w/lib"],
                                       worktrees: ["/w/app": ["/w/app", "/wt/fix-2", "/wt/fix-10"]])
        #expect(tree[0].children.map(\.name) == ["fix-2", "fix-10"])
        #expect(tree[0].children.map(\.kind) == [.worktree, .worktree])
        #expect(tree[1].children.isEmpty)
    }

    /// In the workspace as a repository and a linked worktree of another one
    /// in it: one row, below its repository, so no two rows share an id.
    @Test func aWorktreeThatIsAlsoARepositoryShowsOnce() {
        let tree = WorkspaceTree.build(repos: ["/w/app", "/w/app-fix", "/w/lib"], worktrees: ["/w/app": ["/w/app-fix"]])
        #expect(tree.map(\.id) == ["/w/app", "/w/lib"])
        #expect(tree[0].children.map(\.id) == ["/w/app-fix"])
        #expect(tree[0].children.map(\.kind) == [.worktree])
        let ids = WorkspaceTree.rows(tree, collapsed: []).map(\.id)
        #expect(ids == ["/w/app", "/w/app-fix", "/w/lib"])
        #expect(Set(ids).count == ids.count)
        // Without its repository in the workspace it stays a row of its own.
        #expect(WorkspaceTree.build(repos: ["/w/app-fix", "/w/lib"]).map(\.id) == ["/w/app-fix", "/w/lib"])
    }

    @Test func aRepositoryInsideAnotherKeepsBoth() {
        let tree = WorkspaceTree.build(repos: ["/w/app", "/w/app/plugins/x"])
        #expect(tree.count == 1)
        #expect(tree[0].kind == .repo)
        #expect(tree[0].children.map(\.name) == ["plugins/x"])
        #expect(tree[0].children[0].kind == .repo)
    }

    @Test func rowsSkipWhatIsCollapsed() {
        let tree = WorkspaceTree.build(repos: ["/w/apps/api", "/w/apps/web", "/w/lib"], worktrees: ["/w/lib": ["/wt/lib-2"]])
        let open = WorkspaceTree.rows(tree, collapsed: [])
        #expect(open.map(\.id) == ["/w/apps", "/w/apps/api", "/w/apps/web", "/w/lib", "/wt/lib-2"])
        #expect(open.map(\.depth) == [0, 1, 1, 0, 1])
        let closed = WorkspaceTree.rows(tree, collapsed: ["/w/apps", "/w/lib"])
        #expect(closed.map(\.id) == ["/w/apps", "/w/lib"])
        #expect(closed.map(\.hasChildren) == [true, true])
    }

    @Test func readsAWorktreesFolder() {
        #expect(WorktreeLink.worktreeFolder(gitdirFile: "/wt/fix/.git\n", adminDir: "/w/app/.git/worktrees/fix") == "/wt/fix")
        #expect(WorktreeLink.worktreeFolder(gitdirFile: "../../../../wt/fix/.git", adminDir: "/w/app/.git/worktrees/fix") == "/w/wt/fix")
        #expect(WorktreeLink.worktreeFolder(gitdirFile: "", adminDir: "/x") == nil)
        #expect(WorktreeLink.worktreeFolder(gitdirFile: "/no/git/file", adminDir: "/x") == nil)
    }
}
