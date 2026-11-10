import Testing
@testable import GitCoworkCore

@Suite struct TabReorderTests {
    @Test func landsInTheNearestSlot() {
        #expect(TabReorder.target(from: 0, leadingEdge: 40, stride: 100, count: 4) == 0)
        #expect(TabReorder.target(from: 0, leadingEdge: 60, stride: 100, count: 4) == 1)
        #expect(TabReorder.target(from: 2, leadingEdge: 140, stride: 100, count: 4) == 1)
    }

    @Test func staysInsideTheRow() {
        #expect(TabReorder.target(from: 1, leadingEdge: -500, stride: 100, count: 3) == 0)
        #expect(TabReorder.target(from: 1, leadingEdge: 900, stride: 100, count: 3) == 2)
        #expect(TabReorder.target(from: 0, leadingEdge: 50, stride: 0, count: 3) == 0)
    }

    @Test func othersStepAside() {
        // Dragging 0 to 2: 1 and 2 move left, 3 stays.
        #expect([0, 1, 2, 3].map { TabReorder.shift(of: $0, from: 0, to: 2) } == [0, -1, -1, 0])
        // Dragging 3 to 1: 1 and 2 move right.
        #expect([0, 1, 2, 3].map { TabReorder.shift(of: $0, from: 3, to: 1) } == [0, 1, 1, 0])
        #expect([0, 1, 2].map { TabReorder.shift(of: $0, from: 1, to: 1) } == [0, 0, 0])
    }

    @Test func movesItems() {
        #expect(TabReorder.moved(["a", "b", "c", "d"], from: 0, to: 2) == ["b", "c", "a", "d"])
        #expect(TabReorder.moved(["a", "b", "c", "d"], from: 3, to: 0) == ["d", "a", "b", "c"])
        #expect(TabReorder.moved(["a"], from: 0, to: 4) == ["a"])
    }
}
