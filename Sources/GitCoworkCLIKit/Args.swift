import Foundation

/// Minimal argument parsing: positional words plus `--flag`, `--key value`,
/// `--key=value` and repeatable `--key value`. No dependencies.
public struct Args {
    public private(set) var positional: [String] = []
    private var values: [String: [String]] = [:]
    private var flags: Set<String> = []

    /// Options that take a value; everything else starting with "--" is a flag.
    public static let valued: Set<String> = ["status", "assign", "assignee", "label", "body", "title", "branch",
                                             "to", "base", "task", "remote", "C", "worktree-path"]

    public init(_ argv: [String]) throws {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            i += 1
            if a == "--" { positional += argv[i...]; break }
            if a == "-C" || a == "-h" || a.hasPrefix("--") {
                let name = a == "-C" ? "C" : a == "-h" ? "help" : String(a.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    let key = String(name[..<eq])
                    guard Self.valued.contains(key) else { throw CLIError.usage("--\(key) doesn't take a value") }
                    values[key, default: []].append(String(name[name.index(after: eq)...]))
                } else if Self.valued.contains(name) {
                    guard i < argv.count else { throw CLIError.usage("--\(name) needs a value") }
                    values[name, default: []].append(argv[i])
                    i += 1
                } else {
                    flags.insert(name)
                }
            } else if a.count > 1, a.hasPrefix("-") {
                throw CLIError.usage("unknown option \(a) (put -- before text that starts with -)")
            } else {
                positional.append(a)
            }
        }
    }

    public func flag(_ name: String) -> Bool { flags.contains(name) }
    public func value(_ name: String) -> String? { values[name]?.last }
    public func all(_ name: String) -> [String] { values[name] ?? [] }

    /// Every option given, without the dashes.
    public var optionNames: Set<String> { flags.union(values.keys) }

    /// Positional argument `i`, or a usage error naming what's missing.
    public func arg(_ i: Int, _ what: String) throws -> String {
        guard positional.indices.contains(i) else { throw CLIError.usage("missing \(what)") }
        return positional[i]
    }

    /// Positional words from `i` on, joined with spaces: `new Fix login bug`
    /// gives the title "Fix login bug" without quotes.
    public func text(from i: Int) -> String {
        positional.dropFirst(i).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum CLIError: Error, Equatable {
    /// Wrong use of the command: exit code 2.
    case usage(String)
    /// The command ran but couldn't do it: exit code 1.
    case failed(String)
}
