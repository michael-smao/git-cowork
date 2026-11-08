import Foundation
import Testing
@testable import GitCoworkCore

@Suite struct HostPullsTests {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    // MARK: Requests

    @Test func listRequests() throws {
        let gh = try #require(HostAPI.pullsRequest(kind: .github, host: "github.com", path: "org/app", token: "t"))
        #expect(gh.url?.absoluteString == "https://api.github.com/repos/org/app/pulls?state=open&per_page=100")
        let gl = try #require(HostAPI.pullsRequest(kind: .gitlab, host: "gitlab.com", path: "group/sub/app", token: "t"))
        #expect(gl.url?.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fsub%2Fapp/merge_requests?state=opened&per_page=100")
        let gt = try #require(HostAPI.pullsRequest(kind: .gitea, host: "codeberg.org", path: "org/app", token: "t"))
        #expect(gt.url?.absoluteString == "https://codeberg.org/api/v1/repos/org/app/pulls?state=open&limit=50")
    }

    @Test func repoPathCannotReachOtherEndpoints() {
        for bad in ["../../user", "org/..", "org//app", "app", "org/./app"] {
            #expect(HostAPI.pullsRequest(kind: .github, host: "github.com", path: bad, token: "t") == nil, "\(bad)")
        }
        let odd = HostAPI.pullsRequest(kind: .github, host: "github.com", path: "org/a?b#c", token: "t")
        #expect(odd?.url?.absoluteString == "https://api.github.com/repos/org/a%3Fb%23c/pulls?state=open&per_page=100")
    }

    @Test func createRequestBodies() throws {
        func body(_ r: URLRequest?) throws -> [String: Any] {
            let data = try #require(r?.httpBody)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let gh = HostAPI.createPullRequest(kind: .github, host: "github.com", path: "o/r", token: "t", title: "T",
                                           description: "D", branch: "feat", base: "main", draft: true)
        #expect(gh?.httpMethod == "POST")
        #expect(gh?.url?.absoluteString == "https://api.github.com/repos/o/r/pulls")
        let g = try body(gh)
        #expect(g["head"] as? String == "feat" && g["base"] as? String == "main" && g["draft"] as? Bool == true && g["body"] as? String == "D")

        let lab = try body(HostAPI.createPullRequest(kind: .gitlab, host: "gitlab.com", path: "o/r", token: "t", title: "T",
                                                     description: "D", branch: "feat", base: "main", draft: true))
        #expect(lab["title"] as? String == "Draft: T" && lab["source_branch"] as? String == "feat"
                && lab["target_branch"] as? String == "main" && lab["description"] as? String == "D")

        let tea = try body(HostAPI.createPullRequest(kind: .gitea, host: "c.org", path: "o/r", token: "t", title: "T",
                                                     description: "", branch: "feat", base: "main", draft: true))
        #expect(tea["title"] as? String == "WIP: T" && tea["head"] as? String == "feat")
    }

    // MARK: Parsing

    @Test func readsGitHubPulls() throws {
        let data = json(#"""
        [{"number": 12, "title": "Cache sessions", "draft": false, "html_url": "https://github.com/o/r/pull/12",
          "user": {"login": "anna"},
          "head": {"ref": "feat/x", "sha": "abc1234", "repo": {"full_name": "O/r"}},
          "base": {"ref": "main", "repo": {"full_name": "o/r"}}},
         {"number": 13, "title": "From a fork", "draft": true, "html_url": "javascript:alert(1)",
          "user": {"login": "ben"},
          "head": {"ref": "main", "sha": "def5678", "repo": {"full_name": "ben/r"}},
          "base": {"ref": "main", "repo": {"full_name": "o/r"}}},
         {"number": 14, "title": "Deleted fork", "user": {"login": "c"},
          "head": {"ref": "x", "sha": "aaa1111", "repo": null},
          "base": {"ref": "main", "repo": {"full_name": "o/r"}}},
         {"title": "Broken"}]
        """#)
        let pulls = try #require(HostAPI.parsePulls(data, kind: .github))
        #expect(pulls.map(\.number) == [12, 13, 14])
        #expect(pulls[0] == HostPull(number: 12, title: "Cache sessions", author: "anna", branch: "feat/x", base: "main",
                                     headSHA: "abc1234", webURL: URL(string: "https://github.com/o/r/pull/12"), isDraft: false, isFromFork: false))
        #expect(pulls[1].isFromFork && pulls[1].isDraft && pulls[1].webURL == nil)
        #expect(pulls[2].isFromFork)
    }

    @Test func readsGitLabMergeRequests() throws {
        let data = json(#"""
        [{"iid": 7, "title": "Draft: Fix", "draft": true, "web_url": "https://gitlab.com/o/r/-/merge_requests/7",
          "author": {"username": "anna"}, "source_branch": "fix", "target_branch": "main", "sha": "abc1234",
          "source_project_id": 1, "target_project_id": 1},
         {"iid": 8, "title": "Forked", "source_branch": "fix", "target_branch": "main", "sha": "b",
          "source_project_id": 2, "target_project_id": 1}]
        """#)
        let pulls = try #require(HostAPI.parsePulls(data, kind: .gitlab))
        #expect(pulls[0].number == 7 && pulls[0].branch == "fix" && pulls[0].isDraft && !pulls[0].isFromFork && pulls[0].author == "anna")
        #expect(pulls[1].isFromFork && !pulls[1].isDraft)
    }

    @Test func readsGiteaPullsAndWIPTitles() throws {
        let data = json(#"""
        [{"number": 3, "title": "WIP: thing", "html_url": "https://codeberg.org/o/r/pulls/3", "user": {"login": "a"},
          "head": {"ref": "x", "sha": "abc", "repo": {"full_name": "o/r"}}, "base": {"ref": "main", "repo": {"full_name": "o/r"}}}]
        """#)
        #expect(HostAPI.parsePulls(data, kind: .gitea)?.first?.isDraft == true)
        #expect(HostAPI.parsePulls(json(#"{"message": "Not Found"}"#), kind: .github) == nil)
    }

    @Test func readsCreateAnswers() {
        let ok = json(#"{"number": 5, "title": "T", "head": {"ref": "b", "sha": "a", "repo": {"full_name": "o/r"}}, "base": {"ref": "main", "repo": {"full_name": "o/r"}}}"#)
        if case .created(let p) = HostAPI.parseCreatedPull(status: 201, data: ok, kind: .github) { #expect(p.number == 5) } else { Issue.record("not created") }
        #expect(HostAPI.parseCreatedPull(status: 401, data: Data(), kind: .github) == .signedOut)
        let exists = json(#"{"message": "Validation Failed", "errors": [{"message": "A pull request already exists for o:b."}]}"#)
        #expect(HostAPI.parseCreatedPull(status: 422, data: exists, kind: .github) == .failed("A pull request already exists for o:b."))
        let lab = json(#"{"message": ["Another open merge request already exists"]}"#)
        #expect(HostAPI.parseCreatedPull(status: 409, data: lab, kind: .gitlab) == .failed("Another open merge request already exists"))
    }

    @Test func spotsRateLimits() {
        #expect(HostAPI.isRateLimited(status: 403, remaining: "0", retryAfter: nil))
        #expect(HostAPI.isRateLimited(status: 403, remaining: "12", retryAfter: "60"))
        #expect(HostAPI.isRateLimited(status: 429, remaining: nil, retryAfter: nil))
        #expect(!HostAPI.isRateLimited(status: 403, remaining: "12", retryAfter: nil))
    }

    // MARK: CI

    @Test func ciRequestsPerHost() {
        let sha = "abc1234def"
        #expect(HostAPI.ciRequests(kind: .github, host: "github.com", path: "o/r", sha: sha, token: "t").map(\.url?.absoluteString)
                == ["https://api.github.com/repos/o/r/commits/\(sha)/check-runs?per_page=100",
                    "https://api.github.com/repos/o/r/commits/\(sha)/status?per_page=100"])
        #expect(HostAPI.ciRequests(kind: .gitlab, host: "gitlab.com", path: "o/r", sha: sha, token: "t").first?.url?.absoluteString
                == "https://gitlab.com/api/v4/projects/o%2Fr/repository/commits/\(sha)/statuses?per_page=100")
        #expect(HostAPI.ciRequests(kind: .gitea, host: "c.org", path: "o/r", sha: sha, token: "t").first?.url?.absoluteString
                == "https://c.org/api/v1/repos/o/r/commits/\(sha)/status")
        #expect(HostAPI.ciRequests(kind: .github, host: "github.com", path: "o/r", sha: "../../x", token: "t").isEmpty)
    }

    @Test func readsGitHubCheckRuns() {
        let checks = HostAPI.parseChecks(json(#"""
        {"total_count": 5, "check_runs": [
          {"name": "build", "status": "completed", "conclusion": "success", "html_url": "https://github.com/run/1"},
          {"name": "test", "status": "completed", "conclusion": "failure", "html_url": "https://github.com/run/2"},
          {"name": "lint", "status": "in_progress", "conclusion": null},
          {"name": "skip", "status": "completed", "conclusion": "skipped"},
          {"name": "timeout", "status": "completed", "conclusion": "timed_out"}]}
        """#), host: "github.com")
        #expect(checks.map(\.name) == ["build", "test", "lint", "timeout"])
        #expect(checks.map(\.state) == [.success, .failure, .pending, .failure])
    }

    @Test func emptyCommitStatusIsNotPending() {
        // GitHub's combined status says "pending" when nothing reported at all.
        #expect(HostAPI.parseChecks(json(#"{"state": "pending", "statuses": []}"#), host: "github.com").isEmpty)
    }

    @Test func readsCommitStatusesOfGitHubAndGitea() {
        let gh = HostAPI.parseChecks(json(#"{"state": "failure", "statuses": [{"context": "ci/x", "state": "error", "target_url": "https://ci.example/1"}]}"#), host: "c.org")
        #expect(gh == [CICheck(name: "ci/x", state: .failure, url: URL(string: "https://ci.example/1"))])
        let gitea = HostAPI.parseChecks(json(#"{"state": "success", "statuses": [{"context": "a", "status": "success", "target_url": "file:///etc/passwd"}, {"context": "b", "status": "warning"}]}"#), host: "c.org")
        #expect(gitea == [CICheck(name: "a", state: .success, url: nil)])
    }

    @Test func resolvesForgejoRelativeLinks() {
        let data = json(#"{"statuses": [{"context": "a", "status": "success", "target_url": "/o/r/actions/runs/1"}, {"context": "b", "status": "success", "target_url": "//evil.example/x"}]}"#)
        let checks = HostAPI.parseChecks(data, host: "codeberg.org")
        #expect(checks[0].url?.absoluteString == "https://codeberg.org/o/r/actions/runs/1")
        #expect(checks[1].url == nil)
    }

    @Test func readsGitLabJobs() {
        let checks = HostAPI.parseChecks(json(#"""
        [{"name": "ok", "status": "success", "target_url": "https://gitlab.com/j/1"},
         {"name": "allowed", "status": "failed", "allow_failure": true},
         {"name": "bad", "status": "failed", "allow_failure": false},
         {"name": "wait", "status": "created"},
         {"name": "man", "status": "manual"}]
        """#), host: "gitlab.com")
        #expect(checks.map(\.name) == ["ok", "bad", "wait"])
        #expect(checks.map(\.state) == [.success, .failure, .pending])
    }

    @Test func rollsUpFailedFirst() {
        let c = { (n: String, s: CIState) in CICheck(name: n, state: s, url: nil) }
        #expect(CIResult(checks: []).state == nil)
        #expect(CIResult(checks: [c("a", .success)]).state == .success)
        #expect(CIResult(checks: [c("a", .success), c("b", .pending)]).state == .pending)
        let mixed = CIResult(checks: [c("a", .success), c("b", .pending), c("c", .failure)])
        #expect(mixed.state == .failure)
        #expect(mixed.checks.map(\.name) == ["c", "b", "a"])
        #expect(mixed.count(.success) == 1)
        #expect(CIResult(checks: [c("a", .success), c("a", .failure)]).checks == [c("a", .failure)])
    }

    @Test func pollRules() {
        #expect(HostPollRules.isStale(.pending, age: 30) && !HostPollRules.isStale(.pending, age: 29))
        #expect(HostPollRules.isStale(nil, age: 120) && !HostPollRules.isStale(nil, age: 60))
        #expect(HostPollRules.isStale(.success, age: 600) && !HostPollRules.isStale(.failure, age: 300))
    }
}
