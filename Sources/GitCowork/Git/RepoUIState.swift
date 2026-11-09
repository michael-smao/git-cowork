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
    /// A second choice next to the confirm button (e.g. Rebase beside Merge), already localized.
    var alternativeTitle: String?
    var alternative: (() async -> Void)?
}

/// A failed git action, said in plain words: what happened, what to do next
/// (buttons that run it), and git's own output underneath for the details.
struct GitProblem: Identifiable {
    struct Action: Identifiable {
        enum Role { case primary, normal, destructive }
        let id = UUID()
        let title: String
        var role: Role = .normal
        let run: () async -> Void
    }

    let id = UUID()
    var title: String
    var message: String
    var actions: [Action] = []
    /// "git push origin main", shown like a shell prompt above the output.
    var command: String?
    /// git's raw output (stderr, else stdout).
    var output: String?
    /// Information rather than a failure (e.g. "already deleted on the server").
    var isInfo = false
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
    /// Push a branch that has no upstream yet: pick the remote and the name there.
    case pushTarget(branch: String)
    /// The repository has no remote: add one, then push `branch` if given.
    case addRemote(thenPush: String?)
    /// git doesn't know the user's name and email yet.
    case identity

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
        case .pushTarget(let b): "pushTarget:\(b)"
        case .addRemote(let b): "addRemote:\(b ?? "")"
        case .identity: "identity"
        }
    }
}
