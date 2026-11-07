import Foundation
import GitCoworkCore

/// Pure helpers for the board: filtering, column order, and drop ranks.
/// Kept free of SwiftUI so they're cheap and easy to reason about.
enum BoardLogic {
    /// Column order (TaskOrder, shared with `git cowork list`).
    static func sorted(_ tasks: [CoworkTask], status: TaskStatus) -> [CoworkTask] {
        TaskOrder.sorted(tasks, status: status)
    }

    /// True when the task matches the search text (id, title or body).
    static func matches(_ t: CoworkTask, query: String) -> Bool {
        query.isEmpty
            || t.id.localizedCaseInsensitiveContains(query)
            || t.title.localizedCaseInsensitiveContains(query)
            || t.body.localizedCaseInsensitiveContains(query)
    }

    /// Rank changes needed to put `moving` at `index` of `column`
    /// (`column` is the target column in display order, without `moving`).
    /// Usually one change: a rank between the two neighbours. When a
    /// neighbour has no rank yet, the unranked tasks above the drop point get
    /// ranks too, so the new order sticks.
    static func ranks(inserting moving: String, at index: Int, in column: [CoworkTask]) -> [String: Double] {
        let index = max(0, min(index, column.count))
        var changes: [String: Double] = [:]
        // Give ranks to unranked tasks that end up above the moved one.
        var lastRank: Double?
        for i in 0..<index {
            if let r = column[i].rank, lastRank.map({ r > $0 }) ?? true {
                lastRank = r
            } else {
                let r = (lastRank ?? 0) + 1
                changes[column[i].id] = r
                lastRank = r
            }
        }
        let prev = lastRank
        let next: Double? = index < column.count ? column[index].rank : nil
        if let p = prev, let n = next, n <= p {
            // Equal ranks (two people added tasks at the same time): number
            // the whole column again.
            var all = column.map(\.id)
            all.insert(moving, at: index)
            var renumbered: [String: Double] = [:]
            let current = Dictionary(column.map { ($0.id, $0.rank) }, uniquingKeysWith: { a, _ in a })
            for (i, id) in all.enumerated() where current[id] ?? nil != Double(i + 1) {
                renumbered[id] = Double(i + 1)
            }
            return renumbered
        }
        let value: Double
        switch (prev, next) {
        case let (p?, n?): value = (p + n) / 2
        case let (p?, nil): value = p + 1
        case let (nil, n?): value = n - 1
        case (nil, nil): value = 0
        }
        // An unranked next task sorts below every ranked one, so it stays below.
        changes[moving] = value
        return changes
    }

}
