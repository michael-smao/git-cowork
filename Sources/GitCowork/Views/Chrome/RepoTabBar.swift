import AppKit
import SwiftUI

/// What a tab shows: the repo name, plus the folder for a linked worktree.
struct RepoTabLabel: Equatable {
    var name: String
    var worktree: String?

    var symbol: String { worktree == nil ? "folder" : "arrow.triangle.branch" }
}

/// Repo tabs, GitKraken style. Every repo window is still one tab of a native
/// NSWindow tab group, but the native tab bar is hidden: AppKit only shows it
/// from the second tab on (or after a remembered View > Show Tab Bar), and
/// then below the toolbar. Instead each window draws `RepoTabStrip` in the
/// title row next to the traffic lights, listing its group's windows.
///
/// This tracks the windows and bumps `version` when a tab is added, closed,
/// moved, selected or renamed; the strips read it to redraw. Only
/// notifications and KVO, no timers.
@MainActor @Observable
final class RepoTabs {
    static let shared = RepoTabs()

    private(set) var version = 0

    @ObservationIgnored private var labels: [ObjectIdentifier: RepoTabLabel] = [:]
    @ObservationIgnored private var windowObservers: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    @ObservationIgnored private var groupObservers: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    @ObservationIgnored private var tracked: [ObjectIdentifier: Weak] = [:]
    @ObservationIgnored private var pending = false

    private struct Weak { weak var window: NSWindow? }

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                let closing = note.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated {
                    guard let window else { return }
                    let tabs = RepoTabs.shared
                    if closing {
                        tabs.forget(ObjectIdentifier(window))
                    } else if tabs.tracked[ObjectIdentifier(window)] != nil {
                        // Right away, so the native bar never flashes on a newly selected tab.
                        Self.hideNativeTabBar(in: window)
                    }
                    tabs.setNeedsUpdate()
                }
            }
        }
    }

    /// Starts tracking a repo window and adds its tab strip.
    func install(in window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard tracked[id] == nil else { return }
        tracked[id] = Weak(window: window)
        windowObservers[id] = [
            window.observe(\.title) { _, _ in Self.changed() },
            window.observe(\.tabGroup) { _, _ in Self.changed() },
        ]
        let host = NSHostingView(rootView: RepoTabStrip(window: WindowRef(window)))
        if let close = window.standardWindowButton(.closeButton), let zoom = window.standardWindowButton(.zoomButton),
           let bar = Self.titlebarView(of: close, in: window) {
            // The title row above the expanded toolbar, right of the traffic lights.
            host.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: zoom.trailingAnchor, constant: Theme.Space.l),
                host.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Space.m),
                host.centerYAnchor.constraint(equalTo: close.centerYAnchor),
                host.heightAnchor.constraint(equalToConstant: RepoTabStrip.height),
            ])
        } else {
            // No title row to share: a bar of its own under the toolbar.
            let accessory = NSTitlebarAccessoryViewController()
            host.frame.size.height = RepoTabStrip.height
            accessory.view = host
            accessory.layoutAttribute = .bottom
            window.addTitlebarAccessoryViewController(accessory)
        }
        setNeedsUpdate()
    }

    func label(for window: NSWindow) -> RepoTabLabel? { labels[ObjectIdentifier(window)] }

    func setLabel(_ label: RepoTabLabel?, for window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard labels[id] != label else { return }
        labels[id] = label
        setNeedsUpdate()
    }

    /// Coalesces bursts (a new tab sends become-key, become-main, title and
    /// group changes at once) into one redraw.
    func setNeedsUpdate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [self] in
            pending = false
            update()
        }
    }

    /// For KVO callbacks, which aren't marked as running on the main actor.
    private nonisolated static func changed() {
        DispatchQueue.main.async { RepoTabs.shared.setNeedsUpdate() }
    }

    private func forget(_ id: ObjectIdentifier) {
        tracked[id] = nil
        labels[id] = nil
        windowObservers[id] = nil
    }

    private func update() {
        tracked = tracked.filter { $0.value.window != nil }
        let windows = tracked.values.compactMap(\.window)
        var groups: [ObjectIdentifier: NSWindowTabGroup] = [:]
        for window in windows {
            if let group = window.tabGroup { groups[ObjectIdentifier(group)] = group }
        }
        for (id, group) in groups where groupObservers[id] == nil {
            groupObservers[id] = [
                group.observe(\.windows) { _, _ in Self.changed() },
                group.observe(\.selectedWindow) { _, _ in Self.changed() },
                group.observe(\.isTabBarVisible) { _, _ in Self.changed() },
            ]
        }
        groupObservers = groupObservers.filter { groups[$0.key] != nil }
        for window in windows { Self.hideNativeTabBar(in: window) }
        version &+= 1
    }

    /// AppKit shows its tab bar as soon as a group has a second tab, and
    /// `toggleTabBar` can't hide it then. It is a titlebar accessory, so hide
    /// that accessory instead.
    private static func hideNativeTabBar(in window: NSWindow) {
        for accessory in window.titlebarAccessoryViewControllers
        where !accessory.isHidden && !(accessory.view is NSHostingView<RepoTabStrip>) && containsTabBar(accessory.view) {
            accessory.isHidden = true
        }
    }

    private static func containsTabBar(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("TabBar") || view.subviews.contains { containsTabBar($0) }
    }

    /// The full-width view that holds the traffic lights.
    private static func titlebarView(of button: NSView, in window: NSWindow) -> NSView? {
        var view = button.superview
        while let v = view, v.frame.width < window.frame.width - 1 { view = v.superview }
        return view
    }
}

/// Weak window reference that SwiftUI can hold in a view value.
struct WindowRef {
    weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
}

/// The tab row: one tab per open worktree, × on the selected or hovered tab,
/// middle-click closes, "+" opens a new tab. Empty space drags the window.
struct RepoTabStrip: View {
    static let height: CGFloat = 26
    static let tabHeight: CGFloat = 24

    let window: WindowRef
    private var tabs: RepoTabs { RepoTabs.shared }

    /// One tab's content, read in `body` so a change redraws the strip.
    private struct Item: Identifiable {
        let window: NSWindow
        let name: String
        let detail: String?
        let symbol: String
        let selected: Bool
        var id: ObjectIdentifier { ObjectIdentifier(window) }
    }

    var body: some View {
        let _ = tabs.version
        let windows = window.window.map { $0.tabbedWindows ?? [$0] } ?? []
        let selected = window.window?.tabGroup?.selectedWindow ?? window.window
        let items = windows.map { w in
            let label = tabs.label(for: w)
            return Item(window: w, name: label?.name ?? (w.title.isEmpty ? L("New Tab") : w.title),
                        detail: label?.worktree, symbol: label?.symbol ?? "plus.square.dashed", selected: w === selected)
        }
        TabRowLayout {
            ForEach(items) { item in
                let w = item.window
                RepoTab(title: (item.name, item.detail), symbol: item.symbol,
                        selected: item.selected, canCloseOthers: items.count > 1,
                        select: { select(w) }, close: { w.performClose(nil) },
                        closeOthers: { closeOthers(than: w, in: windows) })
            }
            Button { WindowChrome.newTab(nextTo: window.window) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: Self.tabHeight, height: Self.tabHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverFillStyle(hover: 0.08, pressed: 0.16, radius: Theme.Radius.control))
            .help(Text("New Tab"))
            WindowDragArea()
        }
        .frame(height: Self.height)
    }


    private func select(_ w: NSWindow) {
        if let group = w.tabGroup, group.selectedWindow !== w { group.selectedWindow = w }
        w.makeKeyAndOrderFront(nil)
    }

    private func closeOthers(than keep: NSWindow, in windows: [NSWindow]) {
        for w in windows where w !== keep { w.performClose(nil) }
    }
}

private struct RepoTab: View {
    let title: (name: String, detail: String?)
    let symbol: String
    let selected: Bool
    let canCloseOthers: Bool
    let select: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    @State private var hovering = false

    private enum Style {
        static let fill = 0.04
        static let hoverFill = 0.07
        static let selectedFill = 0.11
        static let closeGlyph = Font.system(size: 9, weight: .bold)
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(Theme.Font.small)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: Theme.Metrics.iconWidth)
            HStack(spacing: Theme.Space.s) {
                Text(verbatim: title.name)
                    .font(selected ? Theme.Font.headline : Theme.Font.body)
                    .foregroundStyle(selected ? .primary : .secondary)
                if let detail = title.detail {
                    Text(verbatim: detail)
                        .font(Theme.Font.small)
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(Style.closeGlyph)
                    .frame(width: Theme.Metrics.iconWidth, height: Theme.Metrics.iconWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverFillStyle(hover: 0.10, pressed: 0.20, radius: Theme.Radius.badge))
            .foregroundStyle(.secondary)
            .opacity(selected || hovering ? 1 : 0)
            .help(Text("Close Tab"))
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.s)
        .frame(height: RepoTabStrip.tabHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Color.primary.opacity(selected ? Style.selectedFill : hovering ? Style.hoverFill : Style.fill)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(selected ? Theme.cardBorder : .clear, lineWidth: Theme.Metrics.hairline))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .overlay(MiddleClick(action: close))
        .help(Text(verbatim: [title.name, title.detail].compactMap { $0 }.joined(separator: " · ")))
        .contextMenu {
            Button("Close Tab", action: close)
            Button("Close Other Tabs", action: closeOthers).disabled(!canCloseOthers)
        }
    }
}

/// Catches only middle clicks; every other event passes through to the tab.
private struct MiddleClick: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged: super.hitTest(point)
            default: nil
            }
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action() } else { super.otherMouseUp(with: event) }
        }
    }
}

/// Empty strip space moves the window, and a double-click does what the
/// system setting says for title bars (zoom by default).
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// Tells the window's tab what to show. Used by the repo view.
struct RepoTabLabelReporter: NSViewRepresentable {
    let label: RepoTabLabel

    func makeNSView(context: Context) -> ReporterView { ReporterView() }
    func updateNSView(_ view: ReporterView, context: Context) { view.label = label }

    final class ReporterView: NSView {
        var label: RepoTabLabel? { didSet { report() } }
        private weak var reported: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil, let reported { RepoTabs.shared.setLabel(nil, for: reported) }
            report()
        }

        private func report() {
            guard let window, let label else { return }
            reported = window
            RepoTabs.shared.setLabel(label, for: window)
        }
    }
}

/// Lays out the strip: the tabs at equal widths like GitKraken's (they shrink
/// when there are many), then "+", then the rest as window drag space. The
/// last two subviews are "+" and the drag area; all others are tabs.
private struct TabRowLayout: Layout {
    private static let tabMinWidth: CGFloat = 72
    private static let tabMaxWidth: CGFloat = 220
    private static let spacing = Theme.Space.xs
    /// Kept free after "+" so the window can always be dragged by the strip.
    private static let dragMinWidth: CGFloat = 40

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? Self.tabMaxWidth, height: proposal.height ?? RepoTabStrip.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let tabCount = subviews.count - 2
        let plus = subviews[tabCount]
        let plusWidth = plus.sizeThatFits(.unspecified).width
        let free = bounds.width - plusWidth - Self.dragMinWidth - Self.spacing * CGFloat(tabCount + 1)
        let tabWidth = tabCount == 0 ? 0 : min(Self.tabMaxWidth, max(Self.tabMinWidth, free / CGFloat(tabCount)))
        var x = bounds.minX
        for tab in subviews.prefix(tabCount) {
            tab.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                      proposal: ProposedViewSize(width: tabWidth, height: RepoTabStrip.tabHeight))
            x += tabWidth + Self.spacing
        }
        plus.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        x += plusWidth + Self.spacing
        subviews[tabCount + 1].place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                                     proposal: ProposedViewSize(width: max(0, bounds.maxX - x), height: bounds.height))
    }
}
