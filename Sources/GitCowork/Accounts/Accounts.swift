import CoworkKit
import Foundation
import GitCoworkCore
import Observation

/// Signed-in accounts, for Settings. The account list is in UserDefaults,
/// the tokens in the Keychain.
@MainActor @Observable
final class AccountStore {
    static let shared = AccountStore()

    private(set) var accounts: [HostAccount] = AccountList.load()

    func add(_ account: HostAccount, tokens: TokenSet) throws {
        var account = account
        // Signing in again (say, to grant a new scope) keeps the account's SSH key.
        if account.sshKey == nil, let old = accounts.first(where: { $0.id == account.id }) {
            account.sshKey = old.sshKey
        }
        guard Keychain.saveTokens(tokens, for: account) else {
            throw AccountError(message: L("Couldn't save the token in the Keychain."))
        }
        accounts = accounts.adding(account)
        AccountList.save(accounts)
        Credentials.shared.reload()
    }

    /// Records the SSH key "Create SSH Key…" made and the host accepted.
    func setSSHKey(_ path: String, for account: HostAccount) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i].sshKey = path
        AccountList.save(accounts)
        Credentials.shared.reload()
    }

    /// Key files stay in ~/.ssh and on the host; the app just stops using them.
    func signOut(_ account: HostAccount) {
        Keychain.delete(account)
        accounts.removeAll { $0.id == account.id }
        AccountList.save(accounts)
        Credentials.shared.reload()
        Credentials.shared.forget(host: account.host)
    }
}

enum AccountList {
    private static let key = Prefs.Key.accounts

    static func load() -> [HostAccount] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([HostAccount].self, from: data)) ?? []
    }

    static func save(_ accounts: [HostAccount]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: key)
    }
}

/// Puts tokens where git finds them: git's credential-cache daemon on a
/// private socket, plus `-c` options that point signed-in hosts at it
/// (see CredentialConfig). Also writes the ssh config that gives SSH remotes
/// on those hosts the account's key, if one was made (see SSHKey). A command
/// gets the accounts its repository uses, one per host (see RepoAccounts).
/// Used by GitRunner from any thread.
final class Credentials: @unchecked Sendable {
    static let shared = Credentials()

    /// How long the daemon keeps a token without being refilled. Every network
    /// command refills it, so this only matters after the app is gone.
    private static let cacheTimeout = 3600

    private let dir: URL
    private let lock = NSLock()
    private var accounts: [HostAccount] = AccountList.load()
    private let refresher = Refresher()

    private init() {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("git-cowork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        Keychain.moveHostItems(to: accounts)
    }

    private var current: [HostAccount] {
        lock.lock(); defer { lock.unlock() }
        return accounts
    }

    /// All signed-in accounts, for working out which ones a repository uses.
    var all: [HostAccount] { current }

    /// The first account on each host: what a command uses unless its
    /// repository says otherwise.
    var defaults: [HostAccount] {
        RepoAccounts.choices(accounts: current, config: "").map(\.current)
    }

    var hasSeveralOnOneHost: Bool {
        let list = current
        return Set(list.map(\.host)).count < list.count
    }

    func reload() {
        let list = AccountList.load()
        lock.lock(); accounts = list; lock.unlock()
        for name in files(prefix: "ssh_config") { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }

    private func files(prefix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix) }
    }

    private func socketPath(for account: HostAccount) -> String {
        dir.appendingPathComponent(CredentialConfig.socketName(for: account, among: current)).path
    }

    /// Sockets that exist right now, whichever accounts made them.
    private var sockets: [String] {
        files(prefix: "credentials").filter { $0.hasSuffix(".sock") }.map { dir.appendingPathComponent($0).path }
    }

    /// `GIT_SSH_COMMAND` for network commands, or nil when none of these
    /// accounts has a key. A missing key file is left out: with IdentitiesOnly,
    /// ssh would otherwise offer no key at all.
    func sshCommand(for selected: [HostAccount]) -> String? {
        let keys = selected.compactMap { account -> (host: String, keyPath: String)? in
            guard let path = account.sshKey, FileManager.default.fileExists(atPath: path) else { return nil }
            return (account.host, path)
        }
        guard !keys.isEmpty else { return nil }
        // Named after its contents, so repositories using different accounts
        // each keep their own file. Also rewritten if the temp folder was cleaned.
        let config = SSHKey.appConfig(keys: keys)
        let url = dir.appendingPathComponent("ssh_config-" + CredentialConfig.shortHash(config))
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data(config.utf8).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return SSHKey.sshCommand(configPath: url.path)
    }

    /// Extra `-c` options for a git command. Empty when nobody signed in.
    func configArgs(for selected: [HostAccount]) -> [String] {
        selected.flatMap { CredentialConfig.configArgs(hosts: [$0.host], socketPath: socketPath(for: $0)) }
    }

    /// Fills the cache before a command that may talk to a server. Refreshes
    /// tokens that are about to expire first.
    func prepare(_ selected: [HostAccount], gitPath: String, env: [String: String]) async {
        for account in selected {
            guard let tokens = await refresher.validTokens(for: account),
                  let input = CredentialConfig.storeInput(host: account.host, username: account.gitUsername, password: tokens.access)
            else { continue }
            await cache(["store"], input: input, socket: socketPath(for: account), gitPath: gitPath, env: env)
        }
    }

    /// The account's tokens for API calls, renewed first if they're about to expire.
    func tokens(for account: HostAccount) async -> TokenSet? {
        await refresher.validTokens(for: account)
    }

    /// Drops a host's tokens from the running daemons. An account still signed
    /// in on that host may have moved to another socket; the next command
    /// fills that one again.
    func forget(host: String) {
        let input = Data("protocol=https\nhost=\(host)\n\n".utf8)
        let runner = GitRunner.shared
        let sockets = sockets
        Task {
            for socket in sockets {
                await cache(["erase"], input: input, socket: socket, gitPath: runner.gitPath, env: runner.environment)
            }
        }
    }

    /// Stops the daemons so no token outlives the app. Called while quitting,
    /// so it waits (briefly) for git to finish.
    func stop() {
        let sockets = sockets
        guard !sockets.isEmpty else { return }
        let runner = GitRunner.shared
        let done = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            for socket in sockets {
                await cache(["exit"], input: Data(), socket: socket, gitPath: runner.gitPath, env: runner.environment)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }

    private func cache(_ action: [String], input: Data, socket: String, gitPath: String, env: [String: String]) async {
        let args = ["credential-cache", "--socket", socket, "--timeout", String(Self.cacheTimeout)] + action
        _ = await Subprocess.run(gitPath, args, input: input, env: env, timeout: 10)
    }
}

/// Reads tokens from the Keychain and renews expiring ones, one refresh per
/// account at a time (GitLab replaces the refresh token on every use, so two
/// refreshes at once would leave one of them holding a dead token).
private actor Refresher {
    private var running: [String: Task<TokenSet?, Never>] = [:]

    func validTokens(for account: HostAccount) async -> TokenSet? {
        if let task = running[account.id] { return await task.value }
        guard let tokens = Keychain.loadTokens(for: account) else { return nil }
        guard tokens.expiresSoon(), let refreshToken = tokens.refresh,
              let clientID = OAuthApps.clientID(for: account.host)
        else { return tokens }

        let task = Task<TokenSet?, Never> {
            guard let fresh = await SignIn.refresh(kind: account.kind, host: account.host,
                                                   clientID: clientID, refreshToken: refreshToken)
            else { return tokens }   // let git try; an auth error tells the user to sign in again
            Keychain.saveTokens(fresh, for: account)
            return fresh
        }
        running[account.id] = task
        let result = await task.value
        running[account.id] = nil
        return result
    }
}
