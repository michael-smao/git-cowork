import Foundation

/// An open pull request (merge request on GitLab), from the host's API.
public struct HostPull: Hashable, Sendable, Identifiable {
    public var number: Int
    public var title: String
    public var author: String
    public var branch: String
    public var base: String
    public var headSHA: String
    public var webURL: URL?
    public var isDraft: Bool
    /// Comes from another repository, so `branch` says nothing about ours.
    public var isFromFork: Bool

    public var id: Int { number }

    public init(number: Int, title: String, author: String, branch: String, base: String, headSHA: String,
                webURL: URL?, isDraft: Bool, isFromFork: Bool) {
        self.number = number
        self.title = title
        self.author = author
        self.branch = branch
        self.base = base
        self.headSHA = headSHA
        self.webURL = webURL
        self.isDraft = isDraft
        self.isFromFork = isFromFork
    }
}

/// Listing and creating pull/merge requests. Builds requests and reads
/// responses; the app does the actual networking.
extension HostAPI {
    /// Most pages followed when listing (100 per page, Gitea 50).
    public static let maxPullPages = 5

    /// "/repos/org/repo" or "/projects/group%2Frepo". Nil when the path isn't
    /// a plain repo path: it comes from the remote URL in the repo's config,
    /// and must not be able to reach any other API endpoint with the token.
    static func repoPrefix(kind: HostKind, path: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let encoded = parts.compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
        return kind == .gitlab ? "/projects/" + encoded.joined(separator: "%2F") : "/repos/" + encoded.joined(separator: "/")
    }

    static func apiURL(kind: HostKind, host: String, path: String, suffix: String) -> URL? {
        guard let prefix = repoPrefix(kind: kind, path: path) else { return nil }
        return URL(string: apiBase(kind: kind, host: host) + prefix + suffix)
    }

    /// First page of the open pull/merge requests of a repo.
    public static func pullsRequest(kind: HostKind, host: String, path: String, token: String) -> URLRequest? {
        let suffix = switch kind {
        case .github: "/pulls?state=open&per_page=100"
        case .gitlab: "/merge_requests?state=opened&per_page=100"
        case .gitea: "/pulls?state=open&limit=50"
        }
        return apiURL(kind: kind, host: host, path: path, suffix: suffix).map { authorized($0, kind: kind, token: token) }
    }

    /// Requests in one page. Nil when the response isn't a list.
    public static func parsePulls(_ data: Data, kind: HostKind) -> [HostPull]? {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return items.compactMap { pull(from: $0, kind: kind) }
    }

    private static func pull(from obj: [String: Any], kind: HostKind) -> HostPull? {
        let number: Int?, branch: String?, base: String?, sha: String?, author: String?, url: String?, draft: Bool, fork: Bool
        let title = obj["title"] as? String ?? ""
        switch kind {
        case .github, .gitea:
            let head = obj["head"] as? [String: Any], target = obj["base"] as? [String: Any]
            number = obj["number"] as? Int
            branch = head?["ref"] as? String
            base = target?["ref"] as? String
            sha = head?["sha"] as? String
            author = (obj["user"] as? [String: Any])?["login"] as? String
            url = obj["html_url"] as? String
            draft = obj["draft"] as? Bool ?? hasDraftPrefix(title)
            let headRepo = (head?["repo"] as? [String: Any])?["full_name"] as? String
            let baseRepo = (target?["repo"] as? [String: Any])?["full_name"] as? String
            // No head repo: the fork was deleted.
            fork = headRepo == nil || headRepo?.lowercased() != baseRepo?.lowercased()
        case .gitlab:
            number = obj["iid"] as? Int
            branch = obj["source_branch"] as? String
            base = obj["target_branch"] as? String
            sha = obj["sha"] as? String
            author = (obj["author"] as? [String: Any])?["username"] as? String
            url = obj["web_url"] as? String
            draft = obj["draft"] as? Bool ?? obj["work_in_progress"] as? Bool ?? hasDraftPrefix(title)
            fork = (obj["source_project_id"] as? Int) != (obj["target_project_id"] as? Int)
        }
        guard let number, let branch, !branch.isEmpty, let base else { return nil }
        return HostPull(number: number, title: title, author: author ?? "", branch: branch, base: base,
                        headSHA: sha ?? "", webURL: url.flatMap(webURL), isDraft: draft, isFromFork: fork)
    }

    private static func hasDraftPrefix(_ title: String) -> Bool {
        let t = title.lowercased()
        return t.hasPrefix("wip:") || t.hasPrefix("[wip]") || t.hasPrefix("draft:")
    }

    /// http(s) only: these links come from the server or from whoever
    /// reports CI, and are opened in the browser.
    static func webURL(_ s: String) -> URL? {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    // MARK: Creating

    /// Opens a request from `branch` into `base`, both on the repo itself.
    /// GitLab and Gitea mark drafts with a title prefix.
    public static func createPullRequest(kind: HostKind, host: String, path: String, token: String, title: String,
                                         description: String, branch: String, base: String, draft: Bool) -> URLRequest? {
        guard let url = apiURL(kind: kind, host: host, path: path, suffix: kind == .gitlab ? "/merge_requests" : "/pulls") else { return nil }
        var body: [String: Any]
        switch kind {
        case .github:
            body = ["title": title, "body": description, "head": branch, "base": base, "draft": draft]
        case .gitlab:
            body = ["title": draft ? "Draft: " + title : title, "description": description,
                    "source_branch": branch, "target_branch": base]
        case .gitea:
            body = ["title": draft ? "WIP: " + title : title, "body": description, "head": branch, "base": base]
        }
        var r = authorized(url, kind: kind, token: token)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    public enum CreatePullResult: Equatable, Sendable {
        case created(HostPull)
        case signedOut
        case failed(String)
    }

    /// Reads the answer to `createPullRequest`. The host's own message says
    /// what's wrong ("A pull request already exists…").
    public static func parseCreatedPull(status: Int, data: Data, kind: HostKind) -> CreatePullResult {
        if status == 401 { return .signedOut }
        guard (200..<300).contains(status) else { return .failed(errorMessage(data) ?? "HTTP \(status)") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let created = pull(from: obj, kind: kind) else { return .failed("HTTP \(status)") }
        return .created(created)
    }

    /// The host says to slow down (GitHub: 403 or 429 with no calls left).
    public static func isRateLimited(status: Int, remaining: String?, retryAfter: String?) -> Bool {
        status == 429 || (status == 403 && (remaining == "0" || retryAfter != nil))
    }
}
