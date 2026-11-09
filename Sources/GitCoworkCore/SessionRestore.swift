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
