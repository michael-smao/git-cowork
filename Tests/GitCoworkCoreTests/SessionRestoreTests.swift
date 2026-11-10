import Testing
@testable import GitCoworkCore

@Suite struct SessionRestoreTests {
    private let all: (String) -> Bool = { _ in true }

    @Test func reopensInTabOrder() {
        let p = SessionRestore.plan(saved: ["/a", "/b", "/c"], selected: "/b", commandLine: [], alreadyOpen: [], exists: all)
        #expect(p == .init(open: ["/a", "/b", "/c"], select: "/b"))
    }

    @Test func skipsRestoredAndMissing() {
        let p = SessionRestore.plan(saved: ["/a", "/b", "/gone"], selected: "/gone", commandLine: [],
                                    alreadyOpen: ["/a"], exists: { $0 != "/gone" })
        #expect(p == .init(open: ["/b"], select: nil))
    }

    @Test func commandLineComesLastAndInFront() {
        let p = SessionRestore.plan(saved: ["/a", "/b"], selected: "/a", commandLine: ["/b", "/x"], alreadyOpen: [], exists: all)
        #expect(p == .init(open: ["/a", "/b", "/x"], select: "/x"))
    }

    @Test func nothingSaved() {
        #expect(SessionRestore.plan(saved: [], selected: nil, commandLine: [], alreadyOpen: [], exists: all) == .init(open: [], select: nil))
    }
}

@Suite struct WorktreeLinkTests {
    @Test func readsTheMainRepository() {
        #expect(WorktreeLink.mainWorktree(gitFile: "gitdir: /Users/me/git/app/.git/worktrees/fix-1\n", worktree: "/Users/me/git/app/.claude/worktrees/fix-1")
                == "/Users/me/git/app")
    }

    @Test func resolvesRelativePaths() {
        #expect(WorktreeLink.mainWorktree(gitFile: "gitdir: ../../app/.git/worktrees/x", worktree: "/w/wt/x") == "/w/app")
    }

    @Test func ignoresOtherFiles() {
        #expect(WorktreeLink.mainWorktree(gitFile: "gitdir: /x/modules/sub", worktree: "/y") == nil)
        #expect(WorktreeLink.mainWorktree(gitFile: "", worktree: "/y") == nil)
    }
}
