import Foundation

/// Which repositories to open when the app starts: the tabs open when it last
/// quit (in tab order), then folders from the command line, without the ones
/// macOS already restored or that are gone from disk.
public enum SessionRestore {
    public struct Plan<Tab: Hashable & Sendable>: Equatable, Sendable {
        /// Tabs to open, in tab order.
        public var open: [Tab]
        /// The tab to bring to the front afterwards, if it's open.
        public var select: Tab?

        public init(open: [Tab], select: Tab?) {
            self.open = open
            self.select = select
        }
    }

    /// Works on paths, or on `TabTarget`s for tabs that also show a workspace.
    public static func plan<Tab: Hashable & Sendable>(saved: [Tab], selected: Tab?, commandLine: [Tab],
                                                      alreadyOpen: Set<Tab>, exists: (Tab) -> Bool) -> Plan<Tab> {
        var seen = alreadyOpen
        var open: [Tab] = []
        for tab in saved + commandLine where !seen.contains(tab) && exists(tab) {
            seen.insert(tab)
            open.append(tab)
        }
        // A folder named on the command line is what the user wants in front.
        let front = commandLine.last(where: { seen.contains($0) }) ?? selected.flatMap { seen.contains($0) ? $0 : nil }
        return Plan(open: open, select: front)
    }

    /// The tabs saved at the last quit. The app saves them twice: `tabs` with
    /// each tab's workspace, and `paths` (the tabs' paths, each once) for older
    /// versions, which read and write only `paths`. When the two no longer
    /// match, an older version ran in between and its `paths` are newer.
    public static func savedTabs(tabs: [TabTarget]?, selectedTab: TabTarget?,
                                 paths: [String], selectedPath: String?) -> (tabs: [TabTarget], selected: TabTarget?) {
        if let tabs, uniquePaths(tabs) == paths {
            return (tabs, selectedTab)
        }
        return (paths.map { TabTarget(path: $0) }, selectedPath.map { TabTarget(path: $0) })
    }

    /// The tabs' paths in order, each once: what goes into `paths`.
    public static func uniquePaths(_ tabs: [TabTarget]) -> [String] {
        var paths: [String] = []
        for path in tabs.compactMap(\.path) where !paths.contains(path) { paths.append(path) }
        return paths
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
