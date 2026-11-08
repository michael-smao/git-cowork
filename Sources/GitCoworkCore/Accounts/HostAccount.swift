import Foundation

/// What git-cowork asks each kind of server for. One list per kind, used for
/// browser sign-in, the "create a token" link and the hints in Settings.
extension HostKind {
    /// Token scopes. GitHub needs `workflow` to push changes to
    /// .github/workflows; `read:org` lists org repos; `write:public_key` adds
    /// an SSH key. GitLab has no scope narrower than `api` that can add an
    /// SSH key (and creating merge requests needs it too). Gitea and Forgejo
    /// only take pasted tokens.
    public var scopes: [String] {
        switch self {
        case .github: ["repo", "workflow", "read:org", "write:public_key"]
        case .gitlab: ["read_user", "api", "write_repository"]
        case .gitea: ["read:user", "write:repository"]
        }
    }

    /// The scope that lets the API add an SSH key; nil where git-cowork can't
    /// add one (Gitea and Forgejo).
    public var sshKeyScope: String? {
        switch self {
        case .github: "write:public_key"
        case .gitlab: "api"
        case .gitea: nil
        }
    }

    /// GitHub and GitLab can take an SSH key through their API.
    public var canAddSSHKey: Bool { sshKeyScope != nil }

    /// The public server of each kind, suggested when signing in.
    public var defaultHost: String {
        switch self {
        case .github: "github.com"
        case .gitlab: "gitlab.com"
        case .gitea: "codeberg.org"
        }
    }
}

/// A signed-in account on one host. A host can have several; `RepoAccounts`
/// says which one a repository uses. The token itself lives in the Keychain.
public struct HostAccount: Codable, Hashable, Sendable, Identifiable {
    public enum Method: String, Codable, Sendable {
        case oauth   // browser sign-in
        case token   // pasted personal access token
    }

    public var host: String       // lowercased, may include a port: "git.example.com:8443"
    public var kind: HostKind
    public var username: String
    public var method: Method
    /// Private key made by "Create SSH Key…" and added to this account on the
    /// host. Nil when there is none (older saved accounts have no such field).
    public var sshKey: String?

    public var id: String { "\(username)@\(host)" }

    public init(host: String, kind: HostKind, username: String, method: Method, sshKey: String? = nil) {
        self.host = host.lowercased()
        self.kind = kind
        self.username = username
        self.method = method
        self.sshKey = sshKey
    }

    public var canAddSSHKey: Bool { kind.canAddSSHKey }

    /// Username git sends over HTTPS. GitLab wants "oauth2" with OAuth tokens;
    /// everywhere else the account name works with the token as password.
    public var gitUsername: String {
        kind == .gitlab && method == .oauth ? "oauth2" : username
    }

    /// Accepts "github.com", "https://gitlab.example.com/", "Git.Example.com:8443".
    /// Returns nil for anything that isn't a plain host name (with optional port).
    public static func normalizeHost(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        while s.hasSuffix("/") { s.removeLast() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-:")
        guard !s.isEmpty, s.allSatisfy(allowed.contains), !s.hasPrefix("."), !s.hasPrefix("-"), !s.hasPrefix(":") else { return nil }
        return s
    }
}

extension Array where Element == HostAccount {
    /// The list with `account` added, or updated if it's already there. Hosts
    /// stay sorted. Within a host the order is the order of adding, so a new
    /// account never takes over from the one repositories already use.
    public func adding(_ account: HostAccount) -> [HostAccount] {
        var list = self
        if let i = list.firstIndex(where: { $0.id == account.id }) {
            list[i] = account
        } else {
            list.insert(account, at: list.lastIndex { $0.host <= account.host }.map { $0 + 1 } ?? 0)
        }
        return list
    }
}

/// An access token and, for hosts whose tokens expire (GitLab), how to renew it.
public struct TokenSet: Codable, Hashable, Sendable {
    public var access: String
    public var refresh: String?
    public var expiresAt: Date?

    public init(access: String, refresh: String? = nil, expiresAt: Date? = nil) {
        self.access = access
        self.refresh = refresh
        self.expiresAt = expiresAt
    }

    /// True when the token runs out within `margin` seconds.
    public func expiresSoon(now: Date = .now, margin: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < margin
    }
}
