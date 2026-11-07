import AppKit
import GitCoworkCore

/// Values the history cells ask for on every draw, worked out once:
/// branch badges per commit, author initials and colors.
@MainActor
final class HistoryDrawCache {
    private var badgesByCommit: [Int: [GraphBadge]] = [:]
    private var initialsByName: [String: String] = [:]
    private var colorByEmail: [String: NSColor] = [:]

    /// Badges index into the loaded history; drop them when it is rebuilt.
    func resetBadges() { badgesByCommit = [:] }

    func badges(_ commit: Int) -> [GraphBadge]? { badgesByCommit[commit] }

    func setBadges(_ b: [GraphBadge], for commit: Int) { badgesByCommit[commit] = b }

    func initials(_ name: String) -> String {
        if let hit = initialsByName[name] { return hit }
        let s = name.initials
        initialsByName[name] = s
        return s
    }

    func authorColor(_ email: String) -> NSColor {
        if let hit = colorByEmail[email] { return hit }
        let c = Theme.personColor(email)
        colorByEmail[email] = c
        return c
    }
}
