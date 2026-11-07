import Foundation

// Debug builds only (see DebugSnapshot.swift).
#if DEBUG

/// Runs git for the self-tests (CoworkSelfTest, UndoSelfTest) and returns
/// trimmed stdout; prints git's error when it fails.
@discardableResult
func sh(_ args: [String], in dir: URL) async -> String {
    let r = await GitRunner.shared.execute(args, in: dir)
    if r.exitCode != 0 { print("  git \(args.joined(separator: " ")) -> \(r.stderr)") }
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

#endif
