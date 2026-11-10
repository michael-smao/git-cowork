import CoworkKit
import Foundation
import GitCoworkCore

/// GitOutput decoded to text, for the command log and error messages.
struct GitResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    init(_ r: GitOutput) {
        self.init(stdout: r.text, stderr: r.errorText, exitCode: r.exitCode)
    }
}

struct GitError: LocalizedError {
    let command: String
    let result: GitResult

    var errorDescription: String? {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        // A private repo the account can't see looks like a missing one.
        let otherAccount = Credentials.shared.hasSeveralOnOneHost ? "\n\n" + L("If another of your accounts has access, pick it for this repository in the status bar.") : ""
        if CredentialConfig.isAuthFailure(err) {
            return err + "\n\nThe server wants you to sign in. Add your account under git-cowork > Settings > Accounts (for SSH remotes, also Create SSH Key there), or set up an SSH key or credential helper for git." + otherAccount
        }
        if err.lowercased().contains("repository not found") { return err + otherAccount }
        if !err.isEmpty { return err }
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "git exited with code \(result.exitCode)" : out
    }
}

/// Runs the git CLI. Every call is a plain `git <args>` in the repo folder,
/// so behaviour matches the terminal: same config, SSH keys, credential
/// helpers and hooks. The one addition: hosts signed in under Settings >
/// Accounts get their token (and SSH key, if one was made) from the app
/// (see Credentials). Processes run through CoworkKit's Subprocess, with the
/// same environment as the `git cowork` tool (GitEnvironment).
final class GitRunner: @unchecked Sendable {
    static let shared = GitRunner()

    private let lock = NSLock()
    private var env: [String: String]
    let gitPath: String

    private init() {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        gitPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

        var e = ProcessInfo.processInfo.environment
        // Apps started from Finder get a minimal PATH. Hooks (husky, lefthook,
        // lint-staged) need node etc., so start with the usual places and
        // replace with the login shell's PATH once we know it.
        let base = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["PATH"] = [e["PATH"], base].compactMap { $0 }.joined(separator: ":")
        env = GitEnvironment.make(e)

        Task.detached(priority: .utility) { [weak self] in await self?.loadLoginShellPath() }
    }

    private func loadLoginShellPath() async {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Don't let a slow shell profile hang anything.
        let r = await Subprocess.run(shell, ["-l", "-c", "printf %s \"$PATH\""], timeout: 5)
        let path = r.line
        guard r.ok, path.contains("/") else { return }
        lock.withLock { env["PATH"] = path + ":" + (env["PATH"] ?? "") }
    }

    /// The environment git runs with (login-shell PATH plus GitEnvironment).
    var environment: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return env
    }

    /// Runs git and returns stdout. Throws `GitError` on an unexpected exit code.
    /// `logged` puts the command in the command log (use it for anything that
    /// changes the repo; reads would only add noise).
    @discardableResult
    func run(_ args: [String], in dir: URL, logged: Bool = false, okCodes: Set<Int32> = [0],
             input: Data? = nil, env extra: [String: String] = [:], account: HostAccount? = nil) async throws -> String {
        let start = Date()
        let result = await execute(args, in: dir, input: input, env: extra, account: account)
        if logged {
            let entry = CommandLog.Entry(args: args, directory: dir, start: start,
                                         duration: Date().timeIntervalSince(start), result: result)
            await MainActor.run { CommandLog.shared.add(entry) }
        }
        guard okCodes.contains(result.exitCode) else {
            throw GitError(command: "git " + args.joined(separator: " "), result: result)
        }
        return result.stdout
    }

    /// Like `run` but never throws; for best-effort reads. `cancellable`
    /// stops git when the calling task is cancelled (see Subprocess.run).
    func tryRun(_ args: [String], in dir: URL, cancellable: Bool = false) async -> String? {
        let r = await executeData(args, in: dir, cancellable: cancellable)
        return r.ok ? r.text : nil
    }

    /// The output's first line without surrounding whitespace, or nil when git
    /// failed or printed nothing. For reads like `rev-parse`.
    func tryLine(_ args: [String], in dir: URL) async -> String? {
        let r = await executeData(args, in: dir)
        return r.ok && !r.line.isEmpty ? r.line : nil
    }

    /// `input` is written to git's stdin; `extra` adds environment variables
    /// (e.g. GIT_INDEX_FILE for writing trees without touching the real index).
    /// `account` overrides the one the folder's repository uses on that host
    /// (cloning, where the repository doesn't exist yet).
    func execute(_ args: [String], in dir: URL, input: Data? = nil, env extra: [String: String] = [:],
                 account: HostAccount? = nil) async -> GitResult {
        GitResult(await executeData(args, in: dir, input: input, env: extra, account: account))
    }

    /// Like `execute`, but stdout stays raw bytes. Diffs need this: decoding
    /// non-UTF-8 content would corrupt patches built from it.
    func executeData(_ args: [String], in dir: URL, input: Data? = nil, env extra: [String: String] = [:],
                     account: HostAccount? = nil, cancellable: Bool = false) async -> GitOutput {
        var env = environment.merging(extra) { _, new in new }
        let credentials = Credentials.shared
        var accounts = credentials.defaults
        if CredentialConfig.needsCredentials(args) {
            accounts = await networkAccounts(in: dir, override: account)
            await credentials.prepare(accounts, gitPath: gitPath, env: env)
            // An SSH key made under Settings > Accounts, unless the person
            // already picked an ssh command themselves.
            if let ssh = credentials.sshCommand(for: accounts), env["GIT_SSH_COMMAND"] == nil, env["GIT_SSH"] == nil,
               await tryRun(["config", "--get", "core.sshCommand"], in: dir) == nil {
                env["GIT_SSH_COMMAND"] = ssh
            }
        }
        let configArgs = GitEnvironment.configArgs + credentials.configArgs(for: accounts)
        return await Subprocess.run(gitPath, configArgs + args, input: input, env: env, dir: dir,
                                    timeout: GitDefaults.timeout(for: args), cancellable: cancellable)
    }

    /// The accounts a command that talks to a server uses, one per host. Only
    /// reads the repository's config when some host has more than one.
    private func networkAccounts(in dir: URL, override: HostAccount?) async -> [HostAccount] {
        let credentials = Credentials.shared
        if let override { return credentials.defaults.map { $0.host == override.host ? override : $0 } }
        guard credentials.hasSeveralOnOneHost else { return credentials.defaults }
        let config = await tryRun(["config", "--get-regexp", RepoAccounts.configPattern], in: dir) ?? ""
        return RepoAccounts.choices(accounts: credentials.all, config: config).map(\.current)
    }
}
