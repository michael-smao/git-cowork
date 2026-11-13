import Foundation

/// A saved set of repositories shown as a tree beside the repository in one
/// tab (a "solution" in Visual Studio terms). Made by scanning a folder or by
/// adding repositories one by one. Stored as JSON in the app's settings.
public struct Workspace: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Repository folders (main worktrees), in the order they were added.
    public var repos: [String]
    /// The folder it was made from, for scanning again.
    public var scanRoot: String?
    /// How many folder levels below `scanRoot` the scan looked.
    public var scanDepth: Int?
    /// The repository shown last, opened first next time.
    public var lastRepo: String?
    /// Repositories removed by hand: scanning again doesn't bring them back.
    /// Optional, so workspaces saved before it existed still load.
    public var removed: [String]?

    public init(id: String = UUID().uuidString, name: String, repos: [String] = [],
                scanRoot: String? = nil, scanDepth: Int? = nil, lastRepo: String? = nil) {
        self.id = id
        self.name = name
        self.repos = []
        self.scanRoot = scanRoot
        self.scanDepth = scanDepth
        self.lastRepo = lastRepo
        append(repos)
    }

    /// Adds the repositories not already in it, keeping their order. Picked
    /// by hand, so one removed earlier is welcome again. Returns how many were new.
    @discardableResult
    public mutating func add(_ paths: [String]) -> Int {
        removed = removed?.filter { !paths.contains($0) }
        if removed?.isEmpty == true { removed = nil }
        return append(paths)
    }

    /// Adds what a scan found, except repositories removed by hand.
    @discardableResult
    public mutating func addScanned(_ paths: [String]) -> Int {
        append(paths.filter { !(removed ?? []).contains($0) })
    }

    public mutating func remove(_ path: String) {
        guard repos.contains(path) else { return }
        repos.removeAll { $0 == path }
        if lastRepo == path { lastRepo = nil }
        removed = (removed ?? []) + [path]
    }

    @discardableResult
    private mutating func append(_ paths: [String]) -> Int {
        var added = 0
        for path in paths where !repos.contains(path) {
            repos.append(path)
            added += 1
        }
        return added
    }

    /// The repository to show when the workspace opens: the last one shown,
    /// else the first.
    public var startRepo: String? {
        if let lastRepo, repos.contains(lastRepo) { return lastRepo }
        return repos.first
    }
}

/// What one tab shows: a repository (or worktree) folder, a workspace, or
/// both. The value SwiftUI opens repo windows with.
public struct TabTarget: Codable, Hashable, Sendable {
    public var path: String?
    /// `Workspace.id`, when the tab shows a workspace's tree.
    public var workspace: String?

    public init(path: String? = nil, workspace: String? = nil) {
        self.path = path
        self.workspace = workspace
    }

    private enum CodingKeys: String, CodingKey { case path, workspace }

    /// Windows saved by macOS before workspaces existed hold a plain path string.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let path = try? single.decode(String.self) {
            self.init(path: path)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try c.decodeIfPresent(String.self, forKey: .path),
                  workspace: try c.decodeIfPresent(String.self, forKey: .workspace))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(path, forKey: .path)
        try c.encodeIfPresent(workspace, forKey: .workspace)
    }

    /// Shows something at all.
    public var isEmpty: Bool { path == nil && workspace == nil }
}
