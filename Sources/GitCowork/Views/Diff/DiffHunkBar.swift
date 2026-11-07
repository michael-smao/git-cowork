import AppKit

// Hunk header rows of DiffCanvas: the "@@ … @@" title and the
// Stage / Unstage / Discard buttons drawn at its right end.

extension DiffCanvas {
    func drawHunkBar(row r: Int, header: String, in rect: NSRect) {
        DiffStyle.hunkBackground.setFill()
        rect.fill()
        // Top border between hunks; the first hunk sits right under the header's divider.
        if rect.minY > 0 {
            DiffStyle.separator.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: Theme.Metrics.hairline).fill()
        }
        if selection?.contains(r) == true { fillSelection(rect.insetBy(dx: 0, dy: 1)) }

        let buttons = buttonRects(in: rect)
        let textRight = (buttons.first?.1.minX ?? rect.maxX) - DiffStyle.buttonSpacing
        let title = NSAttributedString(string: header, attributes: [
            .font: DiffStyle.gutterFont, .foregroundColor: DiffStyle.secondaryText,
        ])
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: rect.minX, y: rect.minY, width: max(0, textRight - rect.minX), height: rect.height).clip()
        title.draw(at: NSPoint(x: DiffStyle.hunkInset, y: rect.minY + (rect.height - gutterTextHeight) / 2))
        NSGraphicsContext.restoreGraphicsState()

        for (action, frame) in buttons {
            let hit = ButtonHit(row: r, action: action)
            let alpha: CGFloat = !actionsEnabled ? 0.05 : pressed == hit ? 0.26 : hover == hit ? 0.18 : 0.10
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: DiffStyle.buttonRadius, yRadius: DiffStyle.buttonRadius)
            // Opaque base first so the hunk band doesn't show through the tint.
            DiffStyle.buttonBase.setFill()
            path.fill()
            action.tint.withAlphaComponent(alpha).setFill()
            path.fill()
            action.tint.withAlphaComponent(actionsEnabled ? 0.55 : 0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            let label = buttonTitle(action)
            let size = label.size()
            label.draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
    }

    private func buttonTitle(_ action: HunkAction) -> NSAttributedString {
        var color: NSColor = !actionsEnabled ? .tertiaryLabelColor : action.tint
        // Same darkening as Color.readableTint in light mode.
        if actionsEnabled, effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua {
            color = color.blended(withFraction: 0.28, of: .black) ?? color
        }
        return NSAttributedString(string: action.title, attributes: [.font: DiffStyle.buttonFont, .foregroundColor: color])
    }

    /// Buttons of a hunk row, left to right, aligned to the right edge.
    private func buttonRects(in rect: NSRect) -> [(HunkAction, NSRect)] {
        var x = rect.maxX - DiffStyle.hunkInset
        var result: [(HunkAction, NSRect)] = []
        for action in actions.reversed() {
            let w = ceil(buttonTitle(action).size().width) + DiffStyle.buttonPadding * 2
            x -= w
            result.append((action, NSRect(x: x, y: rect.midY - DiffStyle.buttonHeight / 2,
                                          width: w, height: DiffStyle.buttonHeight)))
            x -= DiffStyle.buttonSpacing
        }
        return result.reversed()
    }

    func buttonHit(at p: NSPoint) -> ButtonHit? {
        guard !actions.isEmpty, let r = row(atY: p.y, clamped: false), hunkIndex(row: r) != nil else { return nil }
        guard let (action, _) = buttonRects(in: rowRect(r)).first(where: { $0.1.contains(p) }) else { return nil }
        return ButtonHit(row: r, action: action)
    }
}
