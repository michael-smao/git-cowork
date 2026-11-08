import Foundation
import GitCoworkCore
import Observation

/// Open pull requests and CI results of one repository on its host, for the
/// signed-in account. One per repository: all its worktree tabs share it, so
/// they don't each ask the host. Only asks while the app is in front.
@MainActor @Observable
final class HostStatus {
    enum State: Equatable {
        case loading, ready, signedOut
        case failed(String)
    }

    let links: RemoteLinks
    private(set) var state: State = .loading
    private(set) var pulls: [HostPull] = []
    /// By full commit id. Only commits something asked about.
    private(set) var ci: [String: CIResult] = [:]
    /// Goes up when anything above changes; the commit list redraws on it.
    private(set) var version = 0

    @ObservationIgnored private var checkedAt: [String: Date] = [:]
    @ObservationIgnored private var pullsCheckedAt: Date?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var pausedUntil: Date?
    #if DEBUG
    @ObservationIgnored var isDemo = false
    #endif

    private init(links: RemoteLinks) { self.links = links }

    private static var all: [String: HostStatus] = [:]

    /// The shared status for a remote. Nil for a host of unknown kind.
    static func of(_ links: RemoteLinks) -> HostStatus? {
        guard let kind = links.kind else { return nil }
        let key = "\(kind.rawValue):\(links.host)/\(links.path)".lowercased()
        if let known = all[key] { return known }
        let status = HostStatus(links: links)
        all[key] = status
        return status
    }

    /// The account this repository uses on the host, set by RepoModel.
    private(set) var account: HostAccount?

    /// Another account can see different things, so its results start over.
    func use(_ newAccount: HostAccount?) {
        guard newAccount?.id != account?.id else { return }
        account = newAccount
        state = .loading
        pulls = []
        ci = [:]
        checkedAt = [:]
        pullsCheckedAt = nil
        version += 1
    }

    var canCreatePulls: Bool {
        #if DEBUG
        if isDemo { return true }
        #endif
        return account != nil
    }

    /// The open request from this branch of this repository.
    func pull(forBranch name: String) -> HostPull? {
        pulls.first { !$0.isFromFork && $0.branch == name }
    }

    // MARK: Loading

    /// Brings the list and these commits' CI up to date, asking only for what's due.
    func refresh(wanted: Set<String>, force: Bool = false) async {
        #if DEBUG
        if isDemo { return }
        #endif
        guard let account else { signedOut(); return }
        guard !running, (pausedUntil ?? .distantPast) < Date() else { return }
        running = true
        defer { running = false }
        if state == .signedOut { state = .loading }
        guard let token = await Credentials.shared.tokens(for: account)?.access else {
            fail(AccountError.noToken(account.host), keepData: false)
            return
        }
        let due = force || pullsCheckedAt.map { Date().timeIntervalSince($0) >= HostPollRules.pullsInterval } ?? true
        if due { await loadPulls(account, token: token) }

        let commits = wanted.union(pulls.map(\.headSHA)).filter { !$0.isEmpty }
        let stale = commits.filter(isStale).sorted { (checkedAt[$0] ?? .distantPast) < (checkedAt[$1] ?? .distantPast) }
        await loadCI(Array(stale.prefix(HostPollRules.maxCommitsPerRefresh)), account: account, token: token)
    }

    /// CI of one commit, for the selected commit in the inspector.
    func lookUp(_ sha: String) async {
        guard let account, isStale(sha), (pausedUntil ?? .distantPast) < Date(),
              let token = await Credentials.shared.tokens(for: account)?.access else { return }
        await loadCI([sha], account: account, token: token)
    }

    private func isStale(_ sha: String) -> Bool {
        guard let at = checkedAt[sha] else { return true }
        return HostPollRules.isStale(ci[sha]?.state, age: Date().timeIntervalSince(at))
    }

    private func signedOut() {
        guard state != .signedOut else { return }
        state = .signedOut
        pulls = []
        ci = [:]
        checkedAt = [:]
        pullsCheckedAt = nil
        version += 1
    }

    /// A problem signing in always shows. Anything else (offline, say) leaves
    /// what's already on screen alone; the next refresh tries again.
    private func fail(_ error: Error, keepData: Bool = true) {
        let needsSignIn = (error as? AccountError)?.needsSignIn ?? false
        guard !keepData || needsSignIn || state != .ready else { return }
        state = .failed(error.localizedDescription)
        version += 1
    }

    private func loadPulls(_ account: HostAccount, token: String) async {
        let (kind, host) = (account.kind, account.host)
        var request = HostAPI.pullsRequest(kind: kind, host: host, path: links.path, token: token)
        var found: [HostPull] = []
        var pages = 0
        do {
            while let r = request, pages < HostAPI.maxPullPages {
                let (data, response) = try await SignIn.send(r, host: host)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if status == 401 { throw AccountError.tokenRejected(host) }
                if isRateLimited(status, http) { return }
                guard (200..<300).contains(status), let page = HostAPI.parsePulls(data, kind: kind) else {
                    throw AccountError(message: HostAPI.errorMessage(data)
                                       ?? String(localized: "\(host) didn't return a list (HTTP \(status))."))
                }
                found += page
                pages += 1
                request = HostAPI.nextPageRequest(linkHeader: http?.value(forHTTPHeaderField: "Link"), kind: kind, host: host, token: token)
            }
        } catch {
            if self.account?.id == account.id { fail(error) }
            return
        }
        // The repository switched accounts meanwhile: this answer is for the old one.
        guard self.account?.id == account.id else { return }
        pullsCheckedAt = Date()
        guard found != pulls || state != .ready else { return }
        pulls = found
        state = .ready
        version += 1
    }

    private func isRateLimited(_ status: Int, _ http: HTTPURLResponse?) -> Bool {
        guard HostAPI.isRateLimited(status: status, remaining: http?.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
                                    retryAfter: http?.value(forHTTPHeaderField: "Retry-After")) else { return false }
        pausedUntil = Date().addingTimeInterval(HostPollRules.rateLimitPause)
        return true
    }

    private struct Answer: Sendable {
        let sha: String
        var checks: [CICheck] = []
        var rateLimited = false
        var failed = false
    }

    private func loadCI(_ commits: [String], account: HostAccount, token: String) async {
        guard !commits.isEmpty else { return }
        let requests = commits.map { sha in
            (sha, HostAPI.ciRequests(kind: account.kind, host: account.host, path: links.path, sha: sha, token: token))
        }
        // Marked now, so a second caller doesn't ask for the same commit.
        for sha in commits { checkedAt[sha] = Date() }
        let host = account.host
        var changed = false
        var offset = 0
        while offset < requests.count {
            let batch = requests[offset..<min(offset + 5, requests.count)]
            offset += 5
            let answers = await withTaskGroup(of: Answer.self) { group -> [Answer] in
                for (sha, list) in batch { group.addTask { await Self.ask(sha: sha, requests: list, host: host) } }
                return await group.reduce(into: []) { $0.append($1) }
            }
            guard self.account?.id == account.id else { return }
            for answer in answers {
                if answer.rateLimited { pausedUntil = Date().addingTimeInterval(HostPollRules.rateLimitPause) }
                guard !answer.rateLimited, !answer.failed else { checkedAt[answer.sha] = nil; continue }
                let result = CIResult(checks: answer.checks)
                if ci[answer.sha] != result {
                    ci[answer.sha] = result
                    changed = true
                }
            }
        }
        if changed { version += 1 }
    }

    /// Anything but a clear answer counts as "no checks known".
    private nonisolated static func ask(sha: String, requests: [URLRequest], host: String) async -> Answer {
        var answer = Answer(sha: sha)
        for request in requests {
            guard let (data, response) = try? await SignIn.send(request, host: host),
                  let http = response as? HTTPURLResponse else {
                answer.failed = true
                return answer
            }
            if HostAPI.isRateLimited(status: http.statusCode, remaining: http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
                                     retryAfter: http.value(forHTTPHeaderField: "Retry-After")) {
                answer.rateLimited = true
                return answer
            }
            if (200..<300).contains(http.statusCode) { answer.checks += HostAPI.parseChecks(data, host: host) }
        }
        return answer
    }

    // MARK: Creating

    func createPull(title: String, description: String, branch: String, base: String, draft: Bool) async throws -> HostPull {
        guard let account else { throw AccountError.noToken(links.host) }
        guard let token = await Credentials.shared.tokens(for: account)?.access else { throw AccountError.noToken(account.host) }
        guard let request = HostAPI.createPullRequest(kind: account.kind, host: account.host, path: links.path, token: token, title: title,
                                                      description: description, branch: branch, base: base, draft: draft) else {
            throw AccountError(message: String(localized: "\(links.path) isn't a repository path \(account.host) can use."))
        }
        let (data, response) = try await SignIn.send(request, host: account.host)
        switch HostAPI.parseCreatedPull(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data, kind: account.kind) {
        case .created(let pull):
            pulls.insert(pull, at: 0)
            pullsCheckedAt = nil
            version += 1
            return pull
        case .signedOut:
            throw AccountError.tokenRejected(account.host)
        case .failed(let message):
            throw AccountError(message: message)
        }
    }

    #if DEBUG
    /// Fills in sample data for screenshots (GITCOWORK_DEBUG_HOST).
    func showDemo(pulls: [HostPull], ci: [String: CIResult]) {
        isDemo = true
        self.pulls = pulls
        self.ci = ci
        state = .ready
        version += 1
    }
    #endif
}
