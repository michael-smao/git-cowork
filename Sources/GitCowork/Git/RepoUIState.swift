import Foundation
import GitCoworkCore

// What a repo window shows and asks right now. RepoModel holds one of each.

enum HistorySelection: Hashable {
    case workingCopy
    case commit(String)
}

struct WorktreeInfo: Hashable {
    var changes = 0
    var ahead = 0
    var behind = 0
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    var destructive = true
    let action: () async -> Void
}

enum DiffTarget: Hashable {
    case working(FileChange)
    case commit(CommitDetail, FileChange)

    var file: FileChange {
        switch self {
        case .working(let f), .commit(_, let f): f
        }
    }
}

/// What the big middle area shows.
enum CenterMode: String, CaseIterable, Hashable {
    case history, board, reviews

    var title: String {
        switch self {
        case .history: L("History")
        case .board: L("Board")
        case .reviews: L("Reviews")
        }
    }

    var symbol: String {
        switch self {
        case .history: "point.3.connected.trianglepath.dotted"
        case .board: "rectangle.split.3x1"
        case .reviews: "checkmark.bubble"
        }
    }
}

/// Selected task or review (shown in the right panel on Board / Reviews).
enum CoworkSelection: Hashable {
    case task(String)
    case review(String)
}

enum SheetKind: Identifiable {
    case newBranch(from: String, label: String)
    case newTag(sha: String)
    case renameBranch(String)
    case addWorktree(base: String?)
    case stash
    case newTask(status: TaskStatus)
    case requestReview(branch: String)
    case createPull(branch: String)
    case team

    var id: String {
        switch self {
        case .newBranch(let f, _): "branch:\(f)"
        case .newTag(let s): "tag:\(s)"
        case .renameBranch(let b): "rename:\(b)"
        case .addWorktree(let b): "wt:\(b ?? "")"
        case .stash: "stash"
        case .newTask(let s): "task:\(s.rawValue)"
        case .requestReview(let b): "review:\(b)"
        case .createPull(let b): "pull:\(b)"
        case .team: "team"
        }
    }
}
