import Foundation

public enum CIState: String, Hashable, Sendable {
    case pending, success, failure
}

/// One CI job or status on a commit.
public struct CICheck: Hashable, Sendable, Identifiable {
    public var name: String
    public var state: CIState
    public var url: URL?

    public var id: String { name }

    public init(name: String, state: CIState, url: URL?) {
        self.name = name
        self.state = state
        self.url = url
    }
}

/// Everything the host knows about CI on one commit.
public struct CIResult: Hashable, Sendable {
    /// Failed first, then running, then passed. Skipped jobs aren't listed.
    public var checks: [CICheck]

    /// One entry per name, the worst state winning: GitHub can report the
    /// same name as both a check run and a commit status.
    public init(checks: [CICheck]) {
        var seen = Set<String>()
        self.checks = checks.sorted {
            Self.rank($0.state) != Self.rank($1.state) ? Self.rank($0.state) < Self.rank($1.state)
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.filter { seen.insert($0.name).inserted }
    }

    /// Failed if anything failed, running if anything still runs. Nil without checks.
    public var state: CIState? { checks.first?.state }

    public func count(_ state: CIState) -> Int { checks.filter { $0.state == state }.count }

    private static func rank(_ s: CIState) -> Int {
        switch s {
        case .failure: 0
        case .pending: 1
        case .success: 2
        }
    }
}

/// When to ask the host again. Pure logic so it can be tested.
public enum HostPollRules {
    /// Between looks at the list of open pull requests.
    public static let pullsInterval: TimeInterval = 60
    /// Most commits asked about in one go; the rest wait for the next tick.
    public static let maxCommitsPerRefresh = 20
    /// After the host said to slow down.
    public static let rateLimitPause: TimeInterval = 600

    /// Running CI changes soon; a finished result only on a re-run.
    public static func isStale(_ state: CIState?, age: TimeInterval) -> Bool {
        switch state {
        case .pending: age >= 30
        case nil: age >= 120
        case .success, .failure: age >= 600
        }
    }
}

extension HostAPI {
    /// Requests that together give a commit's CI. GitHub keeps Actions (check
    /// runs) and older integrations (commit statuses) apart.
    public static func ciRequests(kind: HostKind, host: String, path: String, sha: String, token: String) -> [URLRequest] {
        guard sha.count >= 7, sha.count <= 64, sha.allSatisfy(\.isHexDigit) else { return [] }
        let suffixes = switch kind {
        case .github: ["/commits/\(sha)/check-runs?per_page=100", "/commits/\(sha)/status?per_page=100"]
        case .gitlab: ["/repository/commits/\(sha)/statuses?per_page=100"]
        case .gitea: ["/commits/\(sha)/status"]
        }
        return suffixes.compactMap { apiURL(kind: kind, host: host, path: path, suffix: $0) }
            .map { authorized($0, kind: kind, token: token) }
    }

    /// Checks in one response; empty for anything it can't read. An error
    /// (a commit the host doesn't have yet, a token without access to checks)
    /// simply means nothing is known.
    public static func parseChecks(_ data: Data, host: String) -> [CICheck] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let jobs = json as? [[String: Any]] { return jobs.compactMap(gitLabCheck) }
        guard let obj = json as? [String: Any] else { return [] }
        if let runs = obj["check_runs"] as? [[String: Any]] { return runs.compactMap(gitHubRun) }
        if let statuses = obj["statuses"] as? [[String: Any]] { return statuses.compactMap { commitStatus($0, host: host) } }
        return []
    }

    /// Forgejo Actions reports links relative to the server ("/org/repo/actions/runs/1").
    private static func targetURL(_ s: String?, host: String) -> URL? {
        guard let s else { return nil }
        if s.hasPrefix("/"), !s.hasPrefix("//") { return URL(string: "https://\(host)\(s)") }
        return webURL(s)
    }

    private static func gitHubRun(_ run: [String: Any]) -> CICheck? {
        guard let name = run["name"] as? String else { return nil }
        let state: CIState?
        if run["status"] as? String != "completed" {
            state = .pending
        } else {
            switch run["conclusion"] as? String {
            case "success": state = .success
            case "failure", "timed_out", "cancelled", "startup_failure": state = .failure
            case "action_required": state = .pending
            default: state = nil   // neutral, skipped, stale
            }
        }
        return state.map { CICheck(name: name, state: $0, url: (run["html_url"] as? String).flatMap(webURL)) }
    }

    /// GitHub says `state`, Gitea and Forgejo say `status`.
    private static func commitStatus(_ status: [String: Any], host: String) -> CICheck? {
        guard let name = status["context"] as? String else { return nil }
        let state: CIState? = switch (status["state"] ?? status["status"]) as? String {
        case "success": .success
        case "failure", "error": .failure
        case "pending": .pending
        default: nil
        }
        return state.map { CICheck(name: name, state: $0, url: targetURL(status["target_url"] as? String, host: host)) }
    }

    private static func gitLabCheck(_ job: [String: Any]) -> CICheck? {
        guard let name = job["name"] as? String else { return nil }
        let state: CIState? = switch job["status"] as? String {
        case "success": .success
        case "failed": job["allow_failure"] as? Bool == true ? nil : .failure
        case "canceled": .failure
        case "running", "pending", "created", "preparing", "waiting_for_resource", "scheduled": .pending
        default: nil   // skipped, manual
        }
        return state.map { CICheck(name: name, state: $0, url: (job["target_url"] as? String).flatMap(webURL)) }
    }
}
