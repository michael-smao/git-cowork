import Foundation

/// Finds the git repositories in a folder, for making a workspace from it.
///
/// Depth counts folder levels below the chosen folder: 1 looks at the folder
/// itself and its direct subfolders. A folder holding `.git` (a directory, or
/// a file for a linked worktree) is a repository; the scan doesn't look
/// inside it. Hidden folders, symlinks and dependency folders are skipped.
public enum RepoScan {
    /// What Settings offers; 1 is the default.
    public static let depthRange = 1...5
    public static let defaultDepth = 1

    /// Folders full of downloaded code, never anyone's own repositories.
    static let skipped: Set<String> = ["node_modules", "Pods", "Carthage", "DerivedData"]

    public struct Entry: Equatable, Sendable {
        public var name: String
        public var isDirectory: Bool
        public var isSymlink: Bool

        public init(name: String, isDirectory: Bool, isSymlink: Bool = false) {
            self.name = name
            self.isDirectory = isDirectory
            self.isSymlink = isSymlink
        }
    }

    /// Repository folders under `root`, in name order, folder by folder.
    /// `list` returns a folder's entries, or nil when it can't be read.
    public static func find(in root: String, depth: Int, list: (String) -> [Entry]?) -> [String] {
        let maxLevel = min(max(depth, depthRange.lowerBound), depthRange.upperBound)
        var found: [String] = []

        func visit(_ dir: String, level: Int) {
            guard let entries = list(dir) else { return }
            if entries.contains(where: { $0.name == ".git" && !$0.isSymlink }) {
                found.append(dir)
                return
            }
            guard level < maxLevel else { return }
            let folders = entries
                .filter { $0.isDirectory && !$0.isSymlink && !$0.name.hasPrefix(".") && !skipped.contains($0.name) }
                .map(\.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for name in folders { visit((dir as NSString).appendingPathComponent(name), level: level + 1) }
        }

        visit(root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root, level: 0)
        return found
    }
}

extension WorktreeLink {
    /// A linked worktree's folder from `.git/worktrees/<name>/gitdir`, which
    /// holds the path of the worktree's `.git` file. Git writes it absolute,
    /// or relative to `adminDir` (the `worktrees/<name>` folder) with
    /// worktree.useRelativePaths.
    public static func worktreeFolder(gitdirFile contents: String, adminDir: String) -> String? {
        guard var dir = contents.split(whereSeparator: \.isNewline).first.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !dir.isEmpty else { return nil }
        if !dir.hasPrefix("/") { dir = (adminDir as NSString).appendingPathComponent(dir) }
        dir = (dir as NSString).standardizingPath
        guard (dir as NSString).lastPathComponent == ".git" else { return nil }
        return (dir as NSString).deletingLastPathComponent
    }
}
