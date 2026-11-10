/// Dragging a tab along a row of equally wide tabs: where it lands and how
/// far the others step aside meanwhile.
public enum TabReorder {
    /// The slot a tab dragged from `from` falls into when its leading edge is
    /// at `x` (relative to the first slot). `stride` is tab width plus spacing.
    /// It moves over once it covers more than half of the next slot.
    public static func target(from: Int, leadingEdge x: Double, stride: Double, count: Int) -> Int {
        guard count > 0, stride > 0 else { return from }
        return min(count - 1, max(0, Int((x / stride).rounded())))
    }

    /// How many slots the tab at `index` steps aside (-1, 0 or +1) while the
    /// tab from `from` hovers over `to`.
    public static func shift(of index: Int, from: Int, to: Int) -> Int {
        if from < to, index > from, index <= to { return -1 }
        if to < from, index >= to, index < from { return 1 }
        return 0
    }

    /// `items` after moving the one at `from` to `to`.
    public static func moved<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), items.indices.contains(to) else { return items }
        var items = items
        items.insert(items.remove(at: from), at: to)
        return items
    }
}
