import Testing
@testable import GitCoworkCore

@Suite struct StashPartsTests {
    @Test func readsTheParentsOfAStashCommit() throws {
        // Base, index, untracked files (git stash push --include-untracked).
        let full = try #require(StashParts(parents: ["base", "index", "untracked"]))
        #expect(full.base == "base")
        #expect(full.untracked == "untracked")

        // Without untracked files there are only two.
        let plain = try #require(StashParts(parents: ["base", "index"]))
        #expect(plain.base == "base")
        #expect(plain.untracked == nil)

        // An ordinary commit isn't a stash.
        #expect(StashParts(parents: ["base"]) == nil)
        #expect(StashParts(parents: []) == nil)
    }

    private func stash(_ message: String) -> Stash {
        Stash(sha: "abc", selector: "stash@{0}", message: message)
    }

    @Test func readsBranchAndTitleFromTheMessage() {
        let named = stash("On main: fix login")
        #expect(named.branch == "main")
        #expect(named.title == "fix login")

        // git's own message only repeats the last commit: no title.
        let auto = stash("WIP on feature/x: 3b629a8 Reopen the repositories")
        #expect(auto.branch == "feature/x")
        #expect(auto.title == nil)

        // The title may hold ": " itself.
        #expect(stash("On main: note: try again").title == "note: try again")
    }

    @Test func handlesDetachedHeadAndOtherMessages() {
        let detached = stash("On (no branch): experiment")
        #expect(detached.branch == nil)
        #expect(detached.title == "experiment")

        // Made with `git stash store -m` or another tool.
        let other = stash("something else")
        #expect(other.branch == nil)
        #expect(other.title == "something else")
        #expect(stash("").title == nil)
    }

    @Test func parsesStashListOutput() {
        let out = "aaa\u{1f}stash@{0}\u{1f}On main: one\nbbb\u{1f}stash@{1}\u{1f}WIP on main: 1234567 two\n"
        let stashes = Parsers.parseStashes(out)
        #expect(stashes.map(\.sha) == ["aaa", "bbb"])
        #expect(stashes.map(\.title) == ["one", nil])
    }
}
