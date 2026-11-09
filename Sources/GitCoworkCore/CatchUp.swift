import Foundation

/// How to bring a branch up to date with another (its upstream, or a remote
/// branch double-clicked in the app), from `git rev-list --left-right --count`.
public enum CatchUp: Equatable, Sendable {
    /// Same commit: nothing to do.
    case upToDate
    /// Only the branch has new commits: nothing to pull.
    case aheadOnly
    /// Only the other side moved: a fast-forward, which can't lose anything.
    case fastForward
    /// Both moved: merge or rebase, which the user picks.
    case diverged(ahead: Int, behind: Int)

    public init(ahead: Int, behind: Int) {
        switch (ahead, behind) {
        case (0, 0): self = .upToDate
        case (_, 0): self = .aheadOnly
        case (0, _): self = .fastForward
        default: self = .diverged(ahead: ahead, behind: behind)
        }
    }

    /// Parses "<ahead>\t<behind>" from `git rev-list --left-right --count A...B`.
    public init?(revListCounts output: String) {
        let parts = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(ahead: parts[0], behind: parts[1])
    }

    /// git config keys that mean the user chose how `git pull` combines
    /// branches. With one set, a plain `git pull` already does what they want.
    public static let pullPreferenceKeys = ["pull.rebase", "pull.ff"]
}
