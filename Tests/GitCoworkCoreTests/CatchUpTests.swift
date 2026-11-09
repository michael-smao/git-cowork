import Testing
@testable import GitCoworkCore

@Suite struct CatchUpTests {
    @Test func decides() {
        #expect(CatchUp(ahead: 0, behind: 0) == .upToDate)
        #expect(CatchUp(ahead: 2, behind: 0) == .aheadOnly)
        #expect(CatchUp(ahead: 0, behind: 3) == .fastForward)
        #expect(CatchUp(ahead: 1, behind: 4) == .diverged(ahead: 1, behind: 4))
    }

    @Test func parsesRevListCounts() {
        #expect(CatchUp(revListCounts: "0\t5\n") == .fastForward)
        #expect(CatchUp(revListCounts: "2 3") == .diverged(ahead: 2, behind: 3))
        #expect(CatchUp(revListCounts: "") == nil)
        #expect(CatchUp(revListCounts: "fatal: no upstream") == nil)
    }
}
