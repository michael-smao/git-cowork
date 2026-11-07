import AppKit
import GitCoworkCore

// Graph column of HistoryCell: lane lines, commit nodes, the dashed WIP
// joins and the badge connector.

extension HistoryCell {
    private func y(_ anchor: GraphLine.Anchor) -> CGFloat {
        switch anchor {
        case .top: 0
        case .middle: midY
        case .bottom: bounds.height
        }
    }

    func drawLines(_ lines: [GraphLine]) {
        let r = GraphStyle.bendRadius
        for line in lines {
            let path = NSBezierPath()
            path.lineWidth = GraphStyle.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let x1 = GraphStyle.x(line.fromLane), y1 = y(line.from)
            let x2 = GraphStyle.x(line.toLane), y2 = y(line.to)
            path.move(to: NSPoint(x: x1, y: y1))
            if x1 == x2 {
                path.line(to: NSPoint(x: x2, y: y2))
            } else if line.from == .middle {
                // Out of a node sideways, then down into the parent's lane.
                let dir: CGFloat = x2 > x1 ? 1 : -1
                path.line(to: NSPoint(x: x2 - dir * r, y: y1))
                path.curve(to: NSPoint(x: x2, y: y1 + r), controlPoint1: NSPoint(x: x2, y: y1), controlPoint2: NSPoint(x: x2, y: y1))
                path.line(to: NSPoint(x: x2, y: y2))
            } else {
                // Down from above, then sideways into the node.
                let dir: CGFloat = x2 > x1 ? 1 : -1
                path.line(to: NSPoint(x: x1, y: y2 - r))
                path.curve(to: NSPoint(x: x1 + dir * r, y: y2), controlPoint1: NSPoint(x: x1, y: y2), controlPoint2: NSPoint(x: x1, y: y2))
                path.line(to: NSPoint(x: x2, y: y2))
            }
            Theme.lane(line.color).setStroke()
            path.stroke()
        }
    }

    /// Dimmed colors are blended toward the background so lines don't show through.
    private func faded(_ color: NSColor) -> NSColor {
        dimmed ? (color.blended(withFraction: 1 - GraphStyle.dimmedAlpha, of: .controlBackgroundColor) ?? color) : color
    }

    /// Commit node: filled with the author's color (same as their avatar
    /// everywhere else) inside a ring of the lane color. Merge dots stay lane-colored.
    func drawNode(cx: CGFloat, color: NSColor, author: NSColor, initials: String, isHead: Bool, isMerge: Bool) {
        let ringColor = faded(color)
        let fill = isMerge ? ringColor : faded(author)
        let d = isMerge ? GraphStyle.mergeDotDiameter : GraphStyle.nodeDiameter
        let rect = NSRect(x: cx - d / 2, y: midY - d / 2, width: d, height: d)

        if isHead {
            let gap = GraphStyle.headRingGap + GraphStyle.headRingWidth / 2
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -gap, dy: -gap))
            ring.lineWidth = GraphStyle.headRingWidth
            ringColor.setStroke()
            ring.stroke()
        }
        fill.setFill()
        NSBezierPath(ovalIn: rect).fill()
        guard !isMerge else { return }
        let w = GraphStyle.nodeRingWidth
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: w / 2, dy: w / 2))
        ring.lineWidth = w
        ringColor.setStroke()
        ring.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: GraphStyle.Text.initials,
            .foregroundColor: GraphStyle.readableText(on: fill).withAlphaComponent(dimmed ? 0.8 : 1),
        ]
        let s = initials as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: cx - size.width / 2, y: midY - size.height / 2), withAttributes: attrs)
    }

    /// Dashed line of another worktree's WIP: down its own lane from the top,
    /// then sideways into the commit node.
    func drawWIPJoin(_ join: HistoryWIPJoin, into cx: CGFloat) {
        let x = GraphStyle.x(join.lane)
        let r = GraphStyle.bendRadius
        let dir: CGFloat = cx > x ? 1 : -1
        let path = NSBezierPath()
        path.lineWidth = 2
        path.setLineDash(GraphStyle.wipDash, count: GraphStyle.wipDash.count, phase: 0)
        path.move(to: NSPoint(x: x, y: 0))
        path.line(to: NSPoint(x: x, y: midY - r))
        path.curve(to: NSPoint(x: x + dir * r, y: midY), controlPoint1: NSPoint(x: x, y: midY), controlPoint2: NSPoint(x: x, y: midY))
        path.line(to: NSPoint(x: cx, y: midY))
        let color = Theme.lane(join.color)
        (join.dimmed ? color.withAlphaComponent(0.6) : color).setStroke()
        path.stroke()
    }

    /// Lanes past the column edge are cut off; fade them out instead of a hard edge.
    func drawClipFade(lanes: Int) {
        guard GraphStyle.x(lanes - 1) + GraphStyle.laneWidth / 2 > bounds.width else { return }
        let w = GraphStyle.clipFadeWidth
        let bg = NSColor.controlBackgroundColor
        NSGradient(starting: bg.withAlphaComponent(0), ending: bg)?
            .draw(in: NSRect(x: bounds.width - w, y: 0, width: w, height: bounds.height), angle: 0)
    }

    /// Thin line tying a branch badge to its node.
    func drawConnector(from x1: CGFloat, to x2: CGFloat, color: NSColor) {
        guard x2 > x1 else { return }
        color.withAlphaComponent(dimmed ? 0.5 : 0.9).setFill()
        let h = GraphStyle.Badge.connectorWidth
        NSRect(x: x1, y: midY - h / 2, width: x2 - x1, height: h).fill()
    }
}
