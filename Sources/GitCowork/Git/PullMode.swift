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

    /// `--autostash`: uncommitted changes are put aside and back instead of
    /// git refusing to pull.
    var args: [String] {
        switch self {
        case .default: ["pull", "--autostash"]
        case .ffOnly: ["pull", "--ff-only", "--autostash"]
        case .rebase: ["pull", "--rebase", "--autostash"]
        case .merge: ["pull", "--no-rebase", "--autostash"]
        }
    }
}
