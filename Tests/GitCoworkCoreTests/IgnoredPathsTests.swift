import Testing
@testable import GitCoworkCore

@Suite struct IgnoredPathsTests {
    @Test func asksAboutEachPathAndTheFoldersAboveIt() {
        let q = IgnoredPaths.questions(for: ["/r/build/sub/a.o", "/r/build/b.o", "/r/top.txt"], under: "/r")
        #expect(q == ["/r/build/", "/r/build/sub/", "/r/build/sub/a.o", "/r/build/b.o", "/r/top.txt"])
    }

    @Test func skipsPathsOutsideTheWorktree() {
        #expect(IgnoredPaths.questions(for: ["/other/x", "/r", "/rr/x"], under: "/r").isEmpty)
    }

    @Test func anIgnoredFolderCoversEverythingInIt() {
        var cache = IgnoredPaths()
        #expect(cache.answer(for: "/r/build/a.o") == .unknown)
        let asked = IgnoredPaths.questions(for: ["/r/build/sub/a.o"], under: "/r")
        cache.learn(asked: asked, ignored: ["/r/build/", "/r/build/sub/", "/r/build/sub/a.o"])
        #expect(cache.answer(for: "/r/build/sub/a.o") == .ignored)
        #expect(cache.answer(for: "/r/build/never/asked.o") == .ignored)
        // A folder that only starts with the same letters is another folder.
        #expect(cache.answer(for: "/r/builder/x.swift") == .unknown)
    }

    @Test func remembersWhatIsNotIgnored() {
        var cache = IgnoredPaths()
        let asked = IgnoredPaths.questions(for: ["/r/src/a.swift", "/r/src/debug.log"], under: "/r")
        cache.learn(asked: asked, ignored: ["/r/src/debug.log"])
        #expect(cache.answer(for: "/r/src/a.swift") == .relevant)
        #expect(cache.answer(for: "/r/src/debug.log") == .ignored)
        // The folder itself wasn't ignored, so another file in it is still open.
        #expect(cache.answer(for: "/r/src/b.swift") == .unknown)
    }

    /// git doesn't report a folder as ignored when a tracked file is in it
    /// (added with -f); only the untracked files there are.
    @Test func aTrackedFileInAnIgnoredFolderStaysRelevant() {
        var cache = IgnoredPaths()
        let asked = IgnoredPaths.questions(for: ["/r/vendor/kept.c", "/r/vendor/junk.o"], under: "/r")
        cache.learn(asked: asked, ignored: ["/r/vendor/junk.o"])
        #expect(cache.answer(for: "/r/vendor/kept.c") == .relevant)
        #expect(cache.answer(for: "/r/vendor/junk.o") == .ignored)
    }

    @Test func forgetsEverything() {
        var cache = IgnoredPaths()
        cache.learn(asked: ["/r/build/", "/r/build/a.o", "/r/a.swift"], ignored: ["/r/build/", "/r/build/a.o"])
        #expect(!cache.isEmpty)
        cache.forget()
        #expect(cache.isEmpty)
        #expect(cache.answer(for: "/r/build/a.o") == .unknown)
        #expect(cache.answer(for: "/r/a.swift") == .unknown)
    }
}

@Suite struct RefreshPacingTests {
    @Test func oneChangeShowsRightAway() {
        #expect(RefreshPacing.wait(sinceLast: nil, lastDuration: 0, watched: true) == RefreshPacing.settle)
        #expect(RefreshPacing.wait(sinceLast: 30, lastDuration: 0.05, watched: true) == RefreshPacing.settle)
        // Also behind another app: only a stream of changes is slowed down.
        #expect(RefreshPacing.wait(sinceLast: 30, lastDuration: 0.05, watched: false) == RefreshPacing.settle)
    }

    @Test func changesThatKeepComingAreReadOncePerGap() {
        #expect(abs(RefreshPacing.wait(sinceLast: 0.3, lastDuration: 0.05, watched: true) - 0.7) < 0.001)
        #expect(abs(RefreshPacing.wait(sinceLast: 0.3, lastDuration: 0.05, watched: false) - 2.7) < 0.001)
    }

    @Test func aSlowRepositoryWaitsLonger() {
        // A read of 1 s: at most a quarter of the time, so 4 s apart.
        #expect(abs(RefreshPacing.wait(sinceLast: 1, lastDuration: 1, watched: true) - 3) < 0.001)
        // But never longer than the cap.
        #expect(RefreshPacing.wait(sinceLast: 0, lastDuration: 60, watched: true) == RefreshPacing.longestGap)
    }
}
