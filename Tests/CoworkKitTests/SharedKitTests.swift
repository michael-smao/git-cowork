import Foundation
import Testing
import CoworkKit
import GitCoworkCore

@Suite struct CoworkRemoteTests {
    @Test func configuredWins() {
        #expect(CoworkRemote.resolve(remotes: ["origin", "up"], configured: "up", hasCoworkRef: { _ in false }) == "up")
        // A configured remote that's gone falls back to the usual rule.
        #expect(CoworkRemote.resolve(remotes: ["origin"], configured: "gone", hasCoworkRef: { _ in false }) == "origin")
    }

    @Test func remoteWithDataBeforeOrigin() {
        #expect(CoworkRemote.resolve(remotes: ["origin", "team"], configured: nil, hasCoworkRef: { $0 == "team" }) == "team")
        #expect(CoworkRemote.resolve(remotes: ["origin", "team"], configured: nil, hasCoworkRef: { _ in true }) == "origin")
        #expect(CoworkRemote.resolve(remotes: ["a", "b"], configured: nil, hasCoworkRef: { _ in false }) == "a")
        #expect(CoworkRemote.resolve(remotes: [], configured: "x", hasCoworkRef: { _ in true }) == nil)
    }

    @Test func remotesWithData() {
        let out = "refs/cowork/remotes/origin/main\nrefs/cowork/remotes/my/fork/main\nrefs/cowork/remotes/x/other\n"
        #expect(CoworkRemote.remotesWithData(out) == ["origin", "my/fork"])
    }

    @Test func appAndToolPickTheSameRemote() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gc-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let git = ProcessGit()
        _ = await git.git(["init", "-q", "-b", "main", dir.path], in: dir)
        _ = await git.git(["remote", "add", "origin", "https://example.invalid/a.git"], in: dir)
        _ = await git.git(["remote", "add", "team", "https://example.invalid/b.git"], in: dir)
        _ = await git.git(["commit", "-q", "--allow-empty", "-m", "i", "--author", "A <a@x.com>"], in: dir,
                          input: nil, env: ["GIT_COMMITTER_NAME": "A", "GIT_COMMITTER_EMAIL": "a@x.com"])
        _ = await git.git(["update-ref", "refs/cowork/remotes/team/main", "HEAD"], in: dir)

        let first = await CoworkRemote.choose(root: dir, git: git)
        #expect(first == CoworkRemote.Choice(remote: "team", worthRemembering: true))
        _ = await git.git(CoworkRemote.rememberArgs("team"), in: dir)
        #expect(await git.git(["config", "cowork.remote"], in: dir).line == "team")
        #expect(await CoworkRemote.choose(root: dir, git: git) == CoworkRemote.Choice(remote: "team", worthRemembering: false))
    }
}

@Suite struct MarkStartedTests {
    @Test func startedChangeMatchesTheBoardRules() {
        var snap = CoworkSnapshot()
        let now = Date()
        snap.tasks = [CoworkTask(id: "CW-1", title: "a", status: .doing, author: "x", created: now, updated: now, rank: 3)]
        let change = CoworkEdit.startedChange(branch: "CW-2-b", me: "me@x.com", in: snap)
        var t = CoworkTask(id: "CW-2", title: "b", status: .todo, author: "x", created: now, updated: now)
        change(&t)
        #expect(t.branch == "CW-2-b" && t.status == .doing && t.rank == 2 && t.assignee == "me@x.com")

        var inReview = CoworkTask(id: "CW-3", title: "c", status: .review, assignee: "ann@x.com", author: "x",
                                  created: now, updated: now)
        change(&inReview)
        #expect(inReview.status == .review && inReview.assignee == "ann@x.com" && inReview.branch == "CW-2-b")
    }
}

@Suite struct SubprocessTests {
    @Test func inputOutputAndExitCode() async {
        let r = await Subprocess.run("/bin/cat", [], input: Data("hi".utf8))
        #expect(r.ok && r.text == "hi")
        let f = await Subprocess.run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
        #expect(f.exitCode == 3 && f.errorText == "oops\n")
    }

    @Test func timeoutStopsTheProgram() async {
        let start = Date()
        let r = await Subprocess.run("/bin/sleep", ["30"], timeout: 0.5)
        #expect(!r.ok && Date().timeIntervalSince(start) < 10)
        #expect(r.errorText.contains("stopped after"))
    }

    @Test func gitEnvironment() {
        let e = GitEnvironment.make(["PATH": "/bin"])
        #expect(e["PATH"] == "/bin" && e["GIT_TERMINAL_PROMPT"] == "0" && e["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(e["LC_ALL"] == "en_US.UTF-8" && e["GIT_EDITOR"] == "true")
        #expect(GitEnvironment.configArgs.contains("core.fsmonitor=false"))
    }
}
