import Foundation

/// Which signed-in account a repository uses on each server.
///
/// A server can have several accounts (personal and work on github.com). For
/// each repository the app takes, in this order: the account picked for it,
/// saved as `git config cowork.<host>.account` in the repository; the account
/// named like the owner in a remote's URL (`alice` for `alice/app`, `origin`
/// first); the account added first on that server.
public enum RepoAccounts {
    /// One server's accounts and the one this repository uses.
    public struct Choice: Hashable, Sendable {
        public let host: String
        public let accounts: [HostAccount]
        public let current: HostAccount
        /// Whether one of the repository's remotes is on this server.
        public let hasRemote: Bool

        public var showsPicker: Bool { hasRemote && accounts.count > 1 }
    }

    /// Where a repository remembers its pick. Git ignores the key, so git in
    /// the terminal is unaffected.
    public static func configKey(host: String) -> String {
        "cowork.\(host).account"
    }

    /// For `git config --get-regexp`: everything `choices` needs, in one call.
    public static let configPattern = #"^(cowork\..+\.account|remote\..+\.url)$"#

    /// One entry per server, in the order of `accounts`. `config` is what
    /// `git config --get-regexp configPattern` printed.
    public static func choices(accounts: [HostAccount], config: String) -> [Choice] {
        var picks: [String: String] = [:]
        var remotes: [(isOrigin: Bool, links: RemoteLinks)] = []
        for line in config.split(whereSeparator: \.isNewline) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = line[..<space], value = String(line[line.index(after: space)...])
            if key.hasPrefix("cowork."), key.hasSuffix(".account") {
                picks[String(key.dropFirst("cowork.".count).dropLast(".account".count))] = value
            } else if let links = RemoteLinks(remoteURL: value) {
                remotes.append((key == "remote.origin.url", links))
            }
        }
        let originFirst = remotes.filter(\.isOrigin) + remotes.filter { !$0.isOrigin }

        var hosts: [String] = []
        for account in accounts where !hosts.contains(account.host) { hosts.append(account.host) }
        return hosts.map { host in
            let own = accounts.filter { $0.host == host }
            let owners = originFirst.map(\.links)
                .filter { $0.host.lowercased() == SSHKey.sshHost(host) }
                .compactMap { $0.path.split(separator: "/").first.map(String.init) }
            let named = (picks[host].map { [$0] } ?? []) + owners
            let match = named.lazy.compactMap { name in own.first { $0.username.lowercased() == name.lowercased() } }.first
            return Choice(host: host, accounts: own, current: match ?? own[0], hasRemote: !owners.isEmpty)
        }
    }

    /// The account for a URL that isn't a remote yet (cloning).
    public static func account(forURL url: String, among accounts: [HostAccount]) -> HostAccount? {
        choices(accounts: accounts, config: "remote.origin.url \(url)").first(where: \.hasRemote)?.current
    }
}
