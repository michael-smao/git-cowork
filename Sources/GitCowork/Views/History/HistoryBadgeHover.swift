import AppKit
import GitCoworkCore

/// Hovering a row's branch badges when some are cut or behind "+N" shows all
/// of them, full width, one per line, over the rows below (like GitKraken).
///
/// One tracking area on the table reports mouse moves; nothing runs while the
/// mouse rests or is elsewhere. The list is a plain view above the table's
/// clip view, so rows keep their height and nothing is laid out again.
@MainActor
final class HistoryBadgeHover: NSResponder {
    private weak var coordinator: HistoryTableCoordinator?
    private weak var table: NSTableView?
    private weak var scroll: NSScrollView?
    private var list: HistoryBadgeListView?
    /// Row whose list is shown, or waiting to be shown.
    private var shownRow: Int?
    private var pendingRow: Int?
    private var pending: DispatchWorkItem?

    /// Rest this long on the badges before they expand; moving between rows
    /// while a list is open switches right away.
    static let delay: TimeInterval = 0.25

    init(coordinator: HistoryTableCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func attach(to table: NSTableView, in scroll: NSScrollView) {
        self.table = table
        self.scroll = scroll
        table.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                             owner: self))
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        // Scrolling or resizing moves rows away from the list: close it, never chase them.
        center.addObserver(self, selector: #selector(close), name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(close), name: NSView.frameDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(close), name: NSApplication.didResignActiveNotification, object: nil)
        #if DEBUG
        // GITCOWORK_DEBUG_HOVER=<row>: expand that row's badges as if hovered, for snapshots.
        if let row = ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_HOVER"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.show(row) }
        }
        #endif
    }

    override func mouseMoved(with event: NSEvent) { update() }
    override func mouseEntered(with event: NSEvent) { update() }
    override func mouseExited(with event: NSEvent) { update() }

    /// Hides the list and forgets a pending one (scrolling, reloads, column resizes).
    @objc func close() {
        cancelPending()
        shownRow = nil
        list?.removeFromSuperview()
        list = nil
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
        pendingRow = nil
    }

    private func update() {
        guard let table, let window = table.window else { return }
        let point = window.mouseLocationOutsideOfEventStream
        // Inside the open list: keep it, also over the rows it covers.
        if let list, let superview = list.superview, list.frame.contains(superview.convert(point, from: nil)) {
            cancelPending()
            return
        }
        guard let row = expandableRow(at: table.convert(point, from: nil)) else {
            close()
            return
        }
        if row == shownRow { cancelPending(); return }
        if shownRow != nil { cancelPending(); show(row); return }
        guard row != pendingRow else { return }
        cancelPending()
        pendingRow = row
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingRow == row else { return }
            self.pending = nil
            self.pendingRow = nil
            // The mouse may have moved on while waiting.
            guard let table = self.table, let window = table.window,
                  self.expandableRow(at: table.convert(window.mouseLocationOutsideOfEventStream, from: nil)) == row else { return }
            self.show(row)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// Row whose badges are under `p` (table coordinates) and hide something.
    private func expandableRow(at p: NSPoint) -> Int? {
        guard NSApp.isActive, let table, let coordinator, table.visibleRect.contains(p),
              let refs = coordinator.column(.refs), !refs.isHidden else { return nil }
        let row = table.row(at: p)
        let col = table.column(withIdentifier: refs.identifier)
        guard row >= 0, row < coordinator.rows.count, col >= 0, case .commit(let i) = coordinator.rows[row] else { return nil }
        let rect = table.frameOfCell(atColumn: col, row: row)
        guard rect.contains(p), let layout = BadgePainter.layout(coordinator.badges(forCommit: i), width: rect.width),
              layout.fit.hidesSomething else { return nil }
        let x = p.x - rect.minX
        return x >= BadgePainter.lead - GraphStyle.Badge.gap && x <= layout.extent + GraphStyle.Badge.gap ? row : nil
    }

    private func show(_ row: Int) {
        guard let table, let scroll, let coordinator, row >= 0, row < coordinator.rows.count, case .commit(let i) = coordinator.rows[row],
              let refs = coordinator.column(.refs) else { return }
        let col = table.column(withIdentifier: refs.identifier)
        guard col >= 0 else { return }
        let badges = coordinator.badges(forCommit: i)
        guard !badges.isEmpty else { return }
        let cell = table.frameOfCell(atColumn: col, row: row)
        let style = GraphStyle.Badge.self
        let anchor = CGPoint(x: cell.minX + BadgePainter.lead, y: cell.midY - style.height / 2)
        let layout = BadgeListLayout.make(widths: badges.map(BadgePainter.fullWidth), badgeHeight: style.height,
                                          spacing: style.listSpacing, padding: style.listPadding,
                                          anchor: anchor, container: table.visibleRect.insetBy(dx: 2, dy: 2))
        let lane = Theme.lane(i < coordinator.graph.count ? coordinator.graph[i].color : 0)

        let view = list ?? HistoryBadgeListView()
        view.onClick = { [weak coordinator] event in coordinator?.badgeListClicked(row: row, event: event) }
        // Right-click on one badge: only that branch's items, plus the commit's.
        view.onMenu = { [weak coordinator] badge in coordinator?.contextMenu(forRow: row, onlyBadge: badge?.name) }
        view.onExit = { [weak self] in self?.update() }
        view.set(badges: badges, layout: layout, lane: lane)
        view.frame = scroll.convert(layout.frame, from: table)
        if view.superview == nil { scroll.addSubview(view, positioned: .above, relativeTo: nil) }
        list = view
        shownRow = row
    }
}

/// The expanded list: a small panel with one full-width badge per line,
/// drawn with the same code as the column.
final class HistoryBadgeListView: NSView {
    var onClick: ((NSEvent) -> Void)?
    var onMenu: ((GraphBadge?) -> NSMenu?)?
    var onExit: (() -> Void)?
    private var badges: [GraphBadge] = []
    private var layout: BadgeListLayout?
    private var lane: NSColor = .labelColor

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(badges: [GraphBadge], layout: BadgeListLayout, lane: NSColor) {
        self.badges = badges
        self.layout = layout
        self.lane = lane
        let r = Theme.Radius.control
        layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: layout.frame.size), cornerWidth: r, cornerHeight: r, transform: nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = Theme.Radius.control
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        guard let layout else { return }
        let style = GraphStyle.Badge.self
        for (n, badge) in badges.enumerated() where n < layout.tops.count {
            let text = max(layout.widths[n] - BadgePainter.chromeWidth(badge), 0)
            BadgePainter.draw(badge, x: style.listPadding, midY: layout.tops[n] + style.height / 2, textWidth: text, lane: lane)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        }
    }

    override func mouseExited(with event: NSEvent) { onExit?() }

    // Clicks act on the row the list belongs to.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        onClick?(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?(badge(at: convert(event.locationInWindow, from: nil))) }

    /// The badge on the line under `p` (view coordinates), if any.
    private func badge(at p: CGPoint) -> GraphBadge? {
        guard let layout else { return nil }
        let height = GraphStyle.Badge.height
        let spacing = GraphStyle.Badge.listSpacing
        for (n, top) in layout.tops.enumerated() where n < badges.count {
            if p.y >= top - spacing / 2, p.y < top + height + spacing / 2 { return badges[n] }
        }
        return nil
    }
}
