import Foundation
import Testing
@testable import GitCoworkCore

// Rules the app and `git cowork` share (one home each in GitCoworkCore).

private let d0 = Date(timeIntervalSince1970: 1_700_000_000)

private func task(_ id: String, _ status: TaskStatus = .todo, rank: Double? = nil, updated: TimeInterval = 0,
                  branch: String? = nil, title: String = "Cache sessions") -> CoworkTask {
    CoworkTask(id: id, title: title, status: status, branch: branch, author: "a@x.com", created: d0,
               updated: d0.addingTimeInterval(updated), rank: rank)
}

private func review(_ reviewers: [String: ReviewVerdict], requester: String = "anna@x.com",
                    status: ReviewStatus = .open, branch: String = "feat/x", base: String = "main") -> ReviewRequest {
    ReviewRequest(id: "R-1", title: "T", branch: branch, base: base, requester: requester,
                  reviewers: reviewers, status: status, created: d0, updated: d0)
}

@Suite struct RefSplitTests {
    @Test func longestKnownRemoteWins() {
        #expect(RefName.splitRemote("origin/feature/x", remotes: ["origin"])! == ("origin", "feature/x"))
        #expect(RefName.splitRemote("team/a/main", remotes: ["team", "team/a"])! == ("team/a", "main"))
    }

    @Test func firstSlashWithoutKnownRemote() {
        #expect(RefName.splitRemote("up/feat/y", remotes: [])! == ("up", "feat/y"))
        #expect(RefName.splitRemote("main", remotes: ["origin"]) == nil)
        #expect(RefName.splitRemote("origin/", remotes: []) == nil)
    }

    @Test func refUsesIt() {
        let ref = Ref(fullName: "refs/remotes/my/fork/topic", name: "my/fork/topic", kind: .remoteBranch, target: "a")
        #expect(ref.remoteName == "my")
        #expect(ref.split(remotes: ["my/fork"])! == ("my/fork", "topic"))
        let local = Ref(fullName: "refs/heads/a/b", name: "a/b", kind: .localBranch, target: "a")
        #expect(local.split(remotes: []) == nil && local.branchNameWithoutRemote == "a/b")
    }
}

@Suite struct SharedBranchNameTests {
    @Test func linkedBranchMustBeValid() {
        #expect(task("CW-1", branch: "feat/ok").linkedBranch == "feat/ok")
        #expect(task("CW-1", branch: "--upload-pack=evil").linkedBranch == nil)
        #expect(task("CW-1", branch: "a..b").linkedBranch == nil)
        #expect(task("CW-1").linkedBranch == nil)
    }

    @Test func reviewBranchesMustBeValid() {
        #expect(review([:]).validBranches! == ("feat/x", "main"))
        #expect(review([:], branch: "-x").validBranches == nil)
        #expect(review([:], base: "main lol").validBranches == nil)
    }

    @Test func startBranchFallsBackToTaskName() {
        #expect(TaskStart.branchName(for: task("CW-a1", branch: "feat/x")) == "feat/x")
        #expect(TaskStart.branchName(for: task("CW-a1", branch: "-bad")) == "CW-a1-cache-sessions")
        #expect(TaskStart.branchName(for: task("CW a1", title: "!!")) == nil)
    }
}

@Suite struct TaskStartPlanTests {
    @Test func here() {
        #expect(TaskStart.plan(branch: "b", hasLocal: true, remoteBranch: "origin/b", base: "origin/main")
                == ["switch", "--end-of-options", "b"])
        #expect(TaskStart.plan(branch: "b", hasLocal: false, remoteBranch: "origin/b", base: "origin/main")
                == ["switch", "--track", "-c", "b", "--end-of-options", "origin/b"])
        #expect(TaskStart.plan(branch: "b", hasLocal: false, remoteBranch: nil, base: "origin/main")
                == ["switch", "--no-track", "-c", "b", "--end-of-options", "origin/main"])
    }

    @Test func worktree() {
        #expect(TaskStart.plan(branch: "b", hasLocal: true, remoteBranch: nil, base: "HEAD", worktreePath: "/w")
                == ["worktree", "add", "--end-of-options", "/w", "b"])
        #expect(TaskStart.plan(branch: "b", hasLocal: false, remoteBranch: "origin/b", base: "HEAD", worktreePath: "/w")
                == ["worktree", "add", "--track", "-b", "b", "--end-of-options", "/w", "origin/b"])
        #expect(TaskStart.plan(branch: "b", hasLocal: false, remoteBranch: nil, base: "HEAD", worktreePath: "/w")
                == ["worktree", "add", "--no-track", "-b", "b", "--end-of-options", "/w", "HEAD"])
    }

    @Test func worktreePath() {
        #expect(WorktreePath.suggest(main: "/src/app", branch: "feat/x") == "/src/app-feat-x")
    }
}

@Suite struct BaseBranchTests {
    @Test func remoteDefaultWhenFetched() {
        let b = BaseBranch.resolve(remote: "origin", remoteHEAD: "main", remoteBranches: ["origin/main"], localBranches: [])
        #expect(b == BaseBranch(ref: "origin/main", name: "main"))
    }

    @Test func localFallbacks() {
        #expect(BaseBranch.resolve(remote: "origin", remoteHEAD: "dev", remoteBranches: [], localBranches: ["dev"])
                == BaseBranch(ref: "dev", name: "dev"))
        #expect(BaseBranch.resolve(remote: nil, remoteHEAD: nil, remoteBranches: [], localBranches: ["master"])
                == BaseBranch(ref: "master", name: "master"))
        #expect(BaseBranch.resolve(remote: nil, remoteHEAD: nil, remoteBranches: [], localBranches: ["x"]) == nil)
    }

    @Test func defaultRemote() {
        #expect(BranchLookup.defaultRemote(upstream: "up/main", remotes: ["origin", "up"]) == "up")
        #expect(BranchLookup.defaultRemote(upstream: nil, remotes: ["a", "origin"]) == "origin")
        #expect(BranchLookup.defaultRemote(upstream: "gone/main", remotes: ["a"]) == "a")
        #expect(BranchLookup.defaultRemote(upstream: nil, remotes: []) == nil)
    }

    @Test func pushArguments() {
        // No upstream yet: the fallback remote becomes it.
        #expect(BranchLookup.pushArguments(branch: "a/b", upstream: nil, remotes: ["origin"], fallbackRemote: "origin")
                == ["push", "-u", "origin", "refs/heads/a/b:refs/heads/a/b"])
        // Tracked: stays on that remote and that remote branch name.
        #expect(BranchLookup.pushArguments(branch: "x", upstream: "my/fork/y", remotes: ["origin", "my/fork"], fallbackRemote: "origin")
                == ["push", "my/fork", "refs/heads/x:refs/heads/y"])
        // The upstream's remote no longer exists: treated as no upstream.
        #expect(BranchLookup.pushArguments(branch: "x", upstream: "gone/x", remotes: ["origin"], fallbackRemote: "origin")
                == ["push", "-u", "origin", "refs/heads/x:refs/heads/x"])
        #expect(BranchLookup.pushArguments(branch: "x", upstream: nil, remotes: [], fallbackRemote: nil) == nil)
    }

    @Test func remoteLookupPrefersRemote() {
        let refs = [Ref(fullName: "refs/remotes/up/x", name: "up/x", kind: .remoteBranch, target: "1"),
                    Ref(fullName: "refs/remotes/origin/x", name: "origin/x", kind: .remoteBranch, target: "2"),
                    Ref(fullName: "refs/remotes/origin/HEAD", name: "origin/HEAD", kind: .remoteBranch, target: "2")]
        #expect(BranchLookup.remote(named: "x", in: refs, preferred: "origin", remotes: ["origin", "up"])?.name == "origin/x")
        #expect(BranchLookup.remote(named: "x", in: refs, preferred: "nope", remotes: ["origin", "up"])?.name == "up/x")
        #expect(BranchLookup.remote(named: "HEAD", in: refs, preferred: nil, remotes: ["origin"]) == nil)
    }
}

@Suite struct ReviewRuleTests {
    @Test func waitingMeansAskedAndUnanswered() {
        #expect(review(["ben@x.com": .requested]).isWaiting(on: "Ben@x.com"))
        #expect(review(["Ben@x.com": .commented]).isWaiting(on: "ben@x.com"))
        #expect(!review(["ben@x.com": .approved]).isWaiting(on: "ben@x.com"))
        #expect(!review(["ben@x.com": .requested], status: .closed).isWaiting(on: "ben@x.com"))
        #expect(!review(["anna@x.com": .requested]).isWaiting(on: "anna@x.com"))   // own request
        #expect(!review(["ben@x.com": .requested]).isWaiting(on: ""))
    }

    @Test func verdictReusesRequestersKey() {
        var r = review(["Ben@X.com": .requested])
        r.setVerdict(.approved, by: "ben@x.com")
        #expect(r.reviewers == ["Ben@X.com": .approved])
        r.setVerdict(.commented, by: "Carl@x.com")
        #expect(r.reviewers["carl@x.com"] == .commented)
    }

    @Test func lookupIgnoresCase() {
        var snap = CoworkSnapshot()
        snap.tasks = [task("CW-a3f9")]
        snap.reviews = [review([:])]
        #expect(snap.task(id: "cw-A3F9")?.id == "CW-a3f9")
        #expect(snap.review(id: "r-1")?.id == "R-1")
        #expect(snap.task(id: "CW-zzzz") == nil)
    }
}

@Suite struct TaskOrderTests {
    @Test func rankedFirstThenNewest() {
        let list = [task("a", updated: 5), task("b", rank: 2), task("c", rank: 1), task("d", updated: 9)]
        #expect(TaskOrder.sorted(list, status: .todo).map(\.id) == ["c", "b", "d", "a"])
    }

    @Test func doneIsNewestFirst() {
        let list = [task("a", .done, rank: 1, updated: 1), task("b", .done, updated: 5)]
        #expect(TaskOrder.sorted(list, status: .done).map(\.id) == ["b", "a"])
    }

    @Test func allColumnsInBoardOrder() {
        let list = [task("d", .done), task("x", .doing), task("b", .backlog), task("t", .todo, rank: 1)]
        #expect(TaskOrder.sorted(list).map(\.id) == ["b", "t", "x", "d"])
    }
}

@Suite struct GitHubReleaseTests {
    @Test func normal() throws {
        let json = #"{"tag_name":"v1.4.0","html_url":"https://github.com/o/r/releases/tag/v1.4.0","body":"Fixes","prerelease":false}"#
        let r = try #require(GitHubRelease.parse(Data(json.utf8)))
        #expect(r.tag == "v1.4.0" && r.version.description == "1.4.0")
        #expect(r.page?.absoluteString == "https://github.com/o/r/releases/tag/v1.4.0")
        #expect(r.notes == "Fixes" && !r.prerelease)
    }

    @Test func prerelease() throws {
        let r = try #require(GitHubRelease.parse(Data(#"{"tag_name":"2.0.0-beta.1","prerelease":true}"#.utf8)))
        #expect(r.prerelease && r.version.prerelease == "beta.1")
    }

    @Test func missingFields() {
        #expect(GitHubRelease.parse(Data(#"{"name":"x"}"#.utf8)) == nil)
        #expect(GitHubRelease.parse(Data(#"{"tag_name":"latest"}"#.utf8)) == nil)
        #expect(GitHubRelease.parse(Data("not json".utf8)) == nil)
        let r = GitHubRelease.parse(Data(#"{"tag_name":"v1.0.0","html_url":"http://insecure"}"#.utf8))
        #expect(r?.page == nil && r?.notes == "" && r?.prerelease == false)
    }
}

@Suite struct HostKindTests {
    @Test func oneScopeListPerKind() {
        #expect(DeviceFlow.scopes(.github) == "repo workflow read:org write:public_key")
        #expect(HostAPI.newTokenPage(kind: .gitlab, host: "gitlab.com")?.absoluteString
                == "https://gitlab.com/-/user_settings/personal_access_tokens?name=git-cowork&scopes=read_user,api,write_repository")
        #expect(HostAPI.newTokenPage(kind: .github, host: "github.com")?.absoluteString
                == "https://github.com/settings/tokens/new?scopes=repo,workflow,read:org,write:public_key&description=git-cowork")
        for kind in HostKind.allCases where kind.canAddSSHKey {
            #expect(kind.scopes.contains(kind.sshKeyScope!))
        }
    }

    @Test func sshKeysAndDefaults() {
        #expect(!HostKind.gitea.canAddSSHKey && HostKind.gitlab.sshKeyScope == "api")
        #expect(HostAPI.addSSHKeyRequest(kind: .gitea, host: "codeberg.org", token: "t", title: "x", publicKey: "k") == nil)
        #expect(HostKind.gitea.defaultHost == "codeberg.org" && HostKind.github.defaultHost == "github.com")
        #expect(HostAPI.rejectsToken(status: 401) && HostAPI.rejectsToken(status: 403) && !HostAPI.rejectsToken(status: 404))
    }

    @Test func cloneFolderName() {
        #expect(RemoteLinks.cloneFolderName("git@github.com:org/app.git") == "app")
        #expect(RemoteLinks.cloneFolderName("https://gitlab.com/g/sub/tool.git/") == "tool")
        #expect(RemoteLinks.cloneFolderName("/srv/repos/local.git") == "local")
        #expect(RemoteLinks.cloneFolderName("") == "")
    }
}
