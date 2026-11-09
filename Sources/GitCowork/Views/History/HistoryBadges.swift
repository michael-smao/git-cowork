import AppKit
import GitCoworkCore

/// Draws branch and tag badges and the "+N" counter. Shared by the
/// Branch / Tag column and the list it expands into on hover, so both look
/// the same.
@MainActor
enum BadgePainter {
    private static let style = GraphStyle.Badge.self

    /// Where the badges of one row go in a column `width` wide.
    struct RowLayout {
        let fit: BadgeRowFit
        /// Right edge of the badges and counter (start of the connector line).
        let extent: CGFloat
    }

    /// Left inset of the first badge: same as the column title and other panels.
    static var lead: CGFloat { Theme.Metrics.panelPadding }

    static func layout(_ badges: [GraphBadge], width: CGFloat) -> RowLayout? {
        guard let first = badges.first else { return nil }
        let remaining = badges.count - 1
        let moreWidth = remaining > 0 ? counterWidth(remaining) + style.gap : 0
        let maxX = width - style.hPadding
        let available = maxX - lead - moreWidth - chromeWidth(first)
        let fit = BadgeRowFit.fit(count: badges.count, nameWidth: nameWidth(first), available: available)
        var x = lead
        if fit.showsFirst { x += chromeWidth(first) + fit.textWidth }
        if let counter = fit.counter { x += (fit.showsFirst ? style.gap : 0) + counterWidth(counter) }
        return RowLayout(fit: fit, extent: x)
    }

    // MARK: Badges

    /// Padding and icons around the name.
    static func chromeWidth(_ badge: GraphBadge) -> CGFloat {
        let leading = badge.leadingIcon.map { GraphSymbols.width($0, size: style.iconSize) + style.iconSpacing } ?? 0
        let trailing = badge.trailingIcons.reduce(0) { $0 + style.iconSpacing + GraphSymbols.width($1, size: style.iconSize) }
        return style.hPadding * 2 + leading + trailing
    }

    /// The checked-out branch's name is bold.
    private static func font(for badge: GraphBadge) -> NSFont { badge.isHead ? style.headFont : style.font }

    static func nameWidth(_ badge: GraphBadge) -> CGFloat {
        ceil((badge.name as NSString).size(withAttributes: [.font: font(for: badge)]).width)
    }

    static func fullWidth(_ badge: GraphBadge) -> CGFloat { chromeWidth(badge) + nameWidth(badge) }

    /// Draws a badge with its name cut to `textWidth`, vertically centered on
    /// `midY`. Returns its rect.
    @discardableResult
    static func draw(_ badge: GraphBadge, x: CGFloat, midY: CGFloat, textWidth: CGFloat, lane: NSColor) -> NSRect {
        let pad = style.hPadding
        let isStrong = badge.isLocal
        let fill: NSColor = isStrong ? GraphStyle.badgeFill(lane) : lane.withAlphaComponent(style.remoteOnlyAlpha)
        let fg: NSColor = isStrong ? GraphStyle.readableText(on: fill) : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font(for: badge), .foregroundColor: fg, .paragraphStyle: truncating]

        let rect = NSRect(x: x, y: midY - style.height / 2, width: chromeWidth(badge) + textWidth, height: style.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.badge, yRadius: Theme.Radius.badge)
        fill.setFill()
        path.fill()
        if badge.isHead {
            // The checked-out branch: a light ring, so it reads at a glance.
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -style.headOutline / 2, dy: -style.headOutline / 2),
                                    xRadius: Theme.Radius.badge + 1, yRadius: Theme.Radius.badge + 1)
            ring.lineWidth = style.headOutline
            NSColor.labelColor.withAlphaComponent(0.85).setStroke()
            ring.stroke()
        } else if !isStrong {
            lane.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        var cx = rect.minX + pad
        if let leading = badge.leadingIcon {
            cx += GraphSymbols.draw(leading, x: cx, midY: midY, size: style.iconSize, color: fg) + style.iconSpacing
        }
        let name = badge.name as NSString
        let th = name.size(withAttributes: attrs).height
        name.draw(with: NSRect(x: cx, y: midY - th / 2, width: textWidth, height: th),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        cx += textWidth
        for icon in badge.trailingIcons {
            cx += style.iconSpacing
            cx += GraphSymbols.draw(icon, x: cx, midY: midY, size: style.iconSize, color: fg.withAlphaComponent(0.9))
        }
        return rect
    }

    // MARK: Counter

    private static let moreAttrs: [NSAttributedString.Key: Any] = [.font: style.moreFont, .foregroundColor: NSColor.secondaryLabelColor]

    static func counterWidth(_ n: Int) -> CGFloat {
        ("+\(n)" as NSString).size(withAttributes: moreAttrs).width + 10
    }

    /// The "+N" pill. Returns its rect.
    @discardableResult
    static func drawCounter(_ n: Int, x: CGFloat, midY: CGFloat, lane: NSColor) -> NSRect {
        let s = "+\(n)" as NSString
        let size = s.size(withAttributes: moreAttrs)
        let rect = NSRect(x: x, y: midY - style.height / 2 + 2, width: size.width + 10, height: style.height - 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.badge, yRadius: Theme.Radius.badge)
        lane.withAlphaComponent(0.22).setFill()
        path.fill()
        s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: midY - size.height / 2), withAttributes: moreAttrs)
        return rect
    }

    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()
}
