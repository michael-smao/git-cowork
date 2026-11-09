import CoreGraphics

/// How a commit's branch and tag badges fit into the Branch / Tag column:
/// the first badge, its name cut to the room left, then a "+N" counter for
/// the rest. When even a short name doesn't fit, only the counter shows.
public struct BadgeRowFit: Equatable, Sendable {
    /// Width for the first badge's name; 0 when only the counter shows.
    public var textWidth: CGFloat
    /// Number in the "+N" counter, nil when there is none.
    public var counter: Int?
    /// A name is cut or badges are behind the counter, so hovering expands them.
    public var hidesSomething: Bool

    public var showsFirst: Bool { textWidth > 0 }

    /// Names are cut to no less than this, else the badge folds into the counter.
    public static let minTextWidth: CGFloat = 20

    /// - Parameters:
    ///   - count: badges on the commit.
    ///   - nameWidth: full width of the first badge's name.
    ///   - available: room for that name once padding, icons and the counter
    ///     for the other badges are taken off.
    public static func fit(count: Int, nameWidth: CGFloat, available: CGFloat) -> BadgeRowFit {
        guard count > 0 else { return BadgeRowFit(textWidth: 0, counter: nil, hidesSomething: false) }
        let width = min(nameWidth, max(available, 0))
        // A short name like "v1" fits whole even below the minimum.
        guard width >= min(nameWidth, minTextWidth), width > 0 else {
            return BadgeRowFit(textWidth: 0, counter: count, hidesSomething: true)
        }
        let rest = count - 1
        return BadgeRowFit(textWidth: width, counter: rest > 0 ? rest : nil,
                           hidesSomething: rest > 0 || width < nameWidth)
    }
}

/// Where the expanded list of a commit's badges goes when its row is hovered:
/// one badge per line, the first where the row's own badge is, dropping down
/// over the rows below, or growing upward when there is no room below.
/// Coordinates are flipped (y grows downward), like the history table.
public struct BadgeListLayout: Equatable, Sendable {
    /// The panel, in the container's coordinates.
    public var frame: CGRect
    /// Top of each badge, relative to the panel.
    public var tops: [CGFloat]
    /// Width each badge may use; less than its full width only when the
    /// container is narrower than the widest badge.
    public var widths: [CGFloat]

    /// - Parameters:
    ///   - widths: full width of each badge.
    ///   - anchor: top-left of the first badge as drawn in the row.
    ///   - container: visible area the panel must stay inside.
    public static func make(widths: [CGFloat], badgeHeight: CGFloat, spacing: CGFloat, padding: CGFloat,
                            anchor: CGPoint, container: CGRect) -> BadgeListLayout {
        let n = widths.count
        guard n > 0 else { return BadgeListLayout(frame: .zero, tops: [], widths: []) }
        let maxInner = max(container.width - padding * 2, 0)
        let fitted = widths.map { min($0, maxInner) }
        let width = (fitted.max() ?? 0) + padding * 2
        let height = CGFloat(n) * badgeHeight + CGFloat(n - 1) * spacing + padding * 2

        var x = anchor.x - padding
        x = min(x, container.maxX - width)
        x = max(x, container.minX)

        var y = anchor.y - padding
        if y + height > container.maxY {
            // Not enough room below: end at the row instead, so the list grows upward.
            y = anchor.y + badgeHeight + padding - height
        }
        y = min(y, container.maxY - height)
        y = max(y, container.minY)

        let tops = (0..<n).map { padding + CGFloat($0) * (badgeHeight + spacing) }
        return BadgeListLayout(frame: CGRect(x: x, y: y, width: width, height: height), tops: tops, widths: fitted)
    }
}
