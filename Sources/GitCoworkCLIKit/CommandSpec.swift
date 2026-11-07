import Foundation

/// What each `git cowork` command accepts, so a typo like `--asign` is an
/// error instead of being silently ignored.
public enum CommandSpec {
    /// Options every command takes.
    public static let common: Set<String> = ["json", "sync", "no-sync", "remote", "C", "help"]

    struct Spec {
        let options: Set<String>
        /// Most positional words after the command; nil = free text at the end.
        let maxArgs: Int?
    }

    static let specs: [String: Spec] = [
        "list": Spec(options: ["mine", "assignee", "status", "label", "all"], maxArgs: 0),
        "show": Spec(options: [], maxArgs: 1),
        "new": Spec(options: ["status", "assign", "label", "body"], maxArgs: nil),
        "edit": Spec(options: ["title", "body", "status", "assign", "label", "branch"], maxArgs: 1),
        "move": Spec(options: [], maxArgs: 2),
        "assign": Spec(options: [], maxArgs: 2),
        "done": Spec(options: [], maxArgs: 1),
        "comment": Spec(options: [], maxArgs: nil),
        "start": Spec(options: ["worktree", "worktree-path"], maxArgs: 1),
        "reviews": Spec(options: ["waiting", "mine", "all"], maxArgs: 0),
        "review": Spec(options: ["to", "base", "title", "body", "task"], maxArgs: 1),
        "approve": Spec(options: [], maxArgs: nil),
        "changes": Spec(options: [], maxArgs: nil),
        "inbox": Spec(options: [], maxArgs: 0),
        "sync": Spec(options: [], maxArgs: 0),
    ]

    static let aliases = ["ls": "list", "tasks": "list", "add": "new", "status": "move"]

    /// The command's main name ("ls" -> "list"), or nil if there's no such command.
    public static func canonical(_ command: String) -> String? {
        let name = aliases[command] ?? command
        return specs[name] == nil ? nil : name
    }

    /// Throws a usage error for an unknown command, an option the command
    /// doesn't take, or extra words after its arguments.
    public static func check(_ args: Args) throws {
        guard let command = args.positional.first else { return }
        guard let name = canonical(command), let spec = specs[name] else {
            throw CLIError.usage("unknown command \(command)")
        }
        let allowed = spec.options.union(common)
        if let bad = args.optionNames.subtracting(allowed).sorted().first {
            let dashes = bad == "C" ? "-" : "--"
            throw CLIError.usage("\(command) doesn't take \(dashes)\(bad)")
        }
        if let max = spec.maxArgs, args.positional.count - 1 > max {
            let extra = args.positional.dropFirst(max + 1).joined(separator: " ")
            throw CLIError.usage("too many arguments for \(command): \(extra)")
        }
    }
}
