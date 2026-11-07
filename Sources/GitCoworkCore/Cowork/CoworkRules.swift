import Foundation

// Rules about tasks and reviews that the app and the `git cowork` tool share,
// so both answer "which task is CW-12?", "is this review waiting for me?" and
// "in what order do tasks go?" the same way.

extension CoworkSnapshot {
    /// The task with this id, ignoring case ("cw-a3f9" finds CW-a3f9).
    public func task(id: String) -> CoworkTask? {
        tasks.first { $0.id == id } ?? tasks.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// The review with this id, ignoring case.
    public func review(id: String) -> ReviewRequest? {
        reviews.first { $0.id == id } ?? reviews.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
}

extension ReviewRequest {
    /// Open, asked of `email`, and not answered yet. Only commenting doesn't
    /// count as an answer: the review still waits for an approval or changes.
    public func isWaiting(on email: String) -> Bool {
        let me = email.lowercased()
        guard status == .open, !me.isEmpty, requester.lowercased() != me else { return false }
        return reviewers.contains { $0.key.lowercased() == me && ($0.value == .requested || $0.value == .commented) }
    }

    /// Records `email`'s verdict, reusing the key the requester wrote, whatever its case.
    public mutating func setVerdict(_ verdict: ReviewVerdict, by email: String) {
        let me = email.lowercased()
        let key = reviewers.keys.first { $0.lowercased() == me } ?? me
        reviewers[key] = verdict
    }
}

/// The order tasks are shown in: board columns and `git cowork list`.
public enum TaskOrder {
    /// One column: ranked tasks first (lower rank on top), then unranked
    /// ones by most recent update. Done is always newest first.
    public static func sorted(_ tasks: [CoworkTask], status: TaskStatus) -> [CoworkTask] {
        if status == .done {
            return tasks.sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.id < $1.id }
        }
        return tasks.sorted { a, b in
            switch (a.rank, b.rank) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.updated != b.updated ? a.updated > b.updated : a.id < b.id
            }
        }
    }

    /// All tasks, column by column (backlog, to do, … done), each in board order.
    public static func sorted(_ tasks: [CoworkTask]) -> [CoworkTask] {
        TaskStatus.allCases.flatMap { s in sorted(tasks.filter { $0.status == s }, status: s) }
    }
}
