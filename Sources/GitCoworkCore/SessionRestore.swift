import Foundation

/// Which repositories to open when the app starts: the tabs open when it last
/// quit (in tab order), then folders from the command line, without the ones
/// macOS already restored or that are gone from disk.
public enum SessionRestore {
    public struct Plan: Equatable, Sendable {
        /// Paths to open, in tab order.
        public var open: [String]
        /// The tab to bring to the front afterwards, if it's open.
        public var select: String?
    }

    public static func plan(saved: [String], selected: String?, commandLine: [String],
                            alreadyOpen: Set<String>, exists: (String) -> Bool) -> Plan {
        var seen = alreadyOpen
        var open: [String] = []
        for path in saved + commandLine where !seen.contains(path) && exists(path) {
            seen.insert(path)
            open.append(path)
        }
        // A folder named on the command line is what the user wants in front.
        let front = commandLine.last(where: { seen.contains($0) }) ?? selected.flatMap { seen.contains($0) ? $0 : nil }
        return Plan(open: open, select: front)
    }
}

/// A linked worktree's `.git` is a file pointing into the main repository:
/// "gitdir: /path/main/.git/worktrees/name". Read without running git, for
/// naming a tab before its repository loads.
public enum WorktreeLink {
    /// The main worktree's folder, or nil when `contents` isn't such a link.
    /// A relative gitdir is resolved against `worktree`.
    public static func mainWorktree(gitFile contents: String, worktree: String) -> String? {
        guard let line = contents.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var dir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !dir.hasPrefix("/") { dir = (worktree as NSString).appendingPathComponent(dir) }
        let parts = (dir as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: false)
        guard let wt = parts.lastIndex(of: "worktrees"), wt > 0, parts[wt - 1] == ".git" else { return nil }
        let main = parts[..<(wt - 1)].joined(separator: "/")
        return main.isEmpty ? "/" : main
    }
}
