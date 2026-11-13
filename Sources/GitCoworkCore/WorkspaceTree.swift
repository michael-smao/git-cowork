import Foundation

/// The tree a workspace shows: folders as they are on disk (below the folder
/// all its repositories share), repositories, and each repository's linked
/// worktrees. A folder holding a single subfolder or repository and nothing
/// else shares one row with it ("clients/acme").
public enum WorkspaceTree {
    public enum Kind: Hashable, Sendable {
        case folder
        case repo
        case worktree
    }

    public struct Node: Hashable, Sendable, Identifiable {
        /// The folder's full path; unique within a tree.
        public var id: String
        public var name: String
        public var kind: Kind
        public var children: [Node]

        public init(id: String, name: String, kind: Kind, children: [Node] = []) {
            self.id = id
            self.name = name
            self.kind = kind
            self.children = children
        }
    }

    public struct Row: Hashable, Sendable, Identifiable {
        public var node: Node
        public var depth: Int
        public var id: String { node.id }
        public var hasChildren: Bool { !node.children.isEmpty }
    }

    /// The folder every repository lies in: their deepest shared parent.
    public static func base(of repos: [String]) -> String {
        let parents = repos.map { ($0 as NSString).deletingLastPathComponent.split(separator: "/").map(String.init) }
        guard var shared = parents.first else { return "/" }
        for parts in parents.dropFirst() {
            shared = Array(zip(shared, parts).prefix { $0 == $1 }.map(\.0))
        }
        return "/" + shared.joined(separator: "/")
    }

    /// `worktrees` maps a repository to its linked worktrees' folders.
    public static func build(repos: [String], worktrees: [String: [String]] = [:]) -> [Node] {
        // A folder that is in the workspace and also a linked worktree of a
        // repository in it shows once, below that repository. Twice would
        // give two rows the same id.
        let linked = Set(repos.flatMap { repo in (worktrees[repo] ?? []).filter { $0 != repo } })
        let repos = repos.filter { !linked.contains($0) }
        let base = base(of: repos)
        let root = Trie()
        for repo in repos {
            let relative = repo.dropFirst(base == "/" ? 1 : base.count + 1)
            var node = root
            var path = base
            for part in relative.split(separator: "/").map(String.init) {
                path = (path as NSString).appendingPathComponent(part)
                node = node.child(part, path: path)
            }
            node.isRepo = true
            node.worktrees = (worktrees[repo] ?? []).filter { $0 != repo }
        }
        return root.nodes()
    }

    /// The rows a list shows: every node whose ancestors are all open.
    /// `collapsed` holds the ids of closed nodes.
    public static func rows(_ nodes: [Node], collapsed: Set<String>, depth: Int = 0) -> [Row] {
        nodes.flatMap { node -> [Row] in
            let row = Row(node: node, depth: depth)
            guard !node.children.isEmpty, !collapsed.contains(node.id) else { return [row] }
            return [row] + rows(node.children, collapsed: collapsed, depth: depth + 1)
        }
    }

    private final class Trie {
        var children: [String: Trie] = [:]
        var path = ""
        var isRepo = false
        var worktrees: [String] = []

        func child(_ name: String, path: String) -> Trie {
            if let existing = children[name] { return existing }
            let new = Trie()
            new.path = path
            children[name] = new
            return new
        }

        func nodes() -> [Node] {
            let sorted = children.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            let made = sorted.map { name, trie in trie.node(name: name) }
            // Folders first, like a project navigator.
            return made.filter { $0.kind == .folder } + made.filter { $0.kind != .folder }
        }

        func node(name: String) -> Node {
            if isRepo {
                let wts = worktrees
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    .map { Node(id: $0, name: ($0 as NSString).lastPathComponent, kind: .worktree) }
                return Node(id: path, name: name, kind: .repo, children: wts + nodes())
            }
            // A folder holding just one folder or repository: one row for both.
            if children.count == 1, let only = children.first {
                var merged = only.value.node(name: only.key)
                merged.name = name + "/" + merged.name
                return merged
            }
            return Node(id: path, name: name, kind: .folder, children: nodes())
        }
    }
}
