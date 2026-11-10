import Foundation

/// The commits a stash is made of. `git stash` saves the working copy as a
/// commit whose first parent is the commit it was made on. The second parent
/// holds the index, and a third (only with `--include-untracked`) the
/// untracked files, as a commit without parents.
public struct StashParts: Hashable, Sendable {
    /// The commit the stash was made on.
    public let base: String
    /// The commit holding the untracked files, if any were stashed.
    public let untracked: String?

    /// Nil when `parents` aren't those of a stash commit.
    public init?(parents: [String]) {
        guard parents.count >= 2 else { return nil }
        base = parents[0]
        untracked = parents.count > 2 ? parents[2] : nil
    }
}

extension Stash {
    /// The branch the stash was made on, read from its message
    /// ("On main: fix login", "WIP on main: 3b629a8 Subject"). Nil when it
    /// was made on a detached HEAD or the message has another shape.
    public var branch: String? {
        guard let (branch, _) = messageParts, branch != "(no branch)" else { return nil }
        return branch
    }

    /// The message given when stashing. Nil for git's own
    /// "WIP on main: 3b629a8 Subject", which only repeats the last commit.
    public var title: String? {
        guard let (_, rest) = messageParts else { return message.isEmpty ? nil : message }
        return message.hasPrefix("WIP on ") || rest.isEmpty ? nil : rest
    }

    /// "On main: fix login" → ("main", "fix login"). Branch names can't hold a colon.
    private var messageParts: (branch: String, rest: String)? {
        let body: Substring
        if message.hasPrefix("WIP on ") {
            body = message.dropFirst("WIP on ".count)
        } else if message.hasPrefix("On ") {
            body = message.dropFirst("On ".count)
        } else {
            return nil
        }
        guard let colon = body.range(of: ": ") else { return nil }
        return (String(body[..<colon.lowerBound]), String(body[colon.upperBound...]))
    }
}
