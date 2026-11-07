import Foundation

/// What a git call returned. Output stays raw bytes; callers decode.
public struct GitOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var ok: Bool { exitCode == 0 }
    public var text: String { String(decoding: stdout, as: UTF8.self) }
    public var errorText: String { String(decoding: stderr, as: UTF8.self) }
    /// stdout without the trailing newline.
    public var line: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Runs git. The app passes its own runner (login-shell PATH, signed-in
/// accounts); the command-line tool uses `ProcessGit`.
public protocol GitExecutor: Sendable {
    func git(_ args: [String], in dir: URL, input: Data?, env: [String: String]) async -> GitOutput
}

extension GitExecutor {
    public func git(_ args: [String], in dir: URL, input: Data? = nil) async -> GitOutput {
        await git(args, in: dir, input: input, env: [:])
    }
}

/// Plain `git` from PATH, never prompting for a password, with the same
/// environment and `-c` options as the app (see GitEnvironment).
public struct ProcessGit: GitExecutor {
    public init() {}

    public func git(_ args: [String], in dir: URL, input: Data?, env extra: [String: String]) async -> GitOutput {
        let env = GitEnvironment.make(ProcessInfo.processInfo.environment).merging(extra) { _, new in new }
        return await Subprocess.run("/usr/bin/env", ["git"] + GitEnvironment.configArgs + args,
                                    input: input, env: env, dir: dir)
    }
}
