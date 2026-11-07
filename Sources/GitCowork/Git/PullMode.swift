import Foundation

/// The Pull button's menu.
enum PullMode: String, CaseIterable {
    case `default`, ffOnly, rebase, merge

    var title: String {
        switch self {
        case .default: L("Pull")
        case .ffOnly: L("Pull (fast-forward only)")
        case .rebase: L("Pull (rebase)")
        case .merge: L("Pull (merge)")
        }
    }

    var args: [String] {
        switch self {
        case .default: ["pull"]
        case .ffOnly: ["pull", "--ff-only"]
        case .rebase: ["pull", "--rebase"]
        case .merge: ["pull", "--no-rebase"]
        }
    }
}
