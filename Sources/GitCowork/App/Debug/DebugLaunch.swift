import AppKit

// Debug builds only (see DebugSnapshot.swift).
#if DEBUG

/// Keeps runs from a terminal out of the way of whoever is working at the Mac.
///
/// A self-test needs no window: the app starts without a Dock icon, never
/// becomes the active app and hides every window it opens. A snapshot needs
/// one, so its window goes to a screen other than the one with the mouse
/// pointer (or behind the other apps' windows, with a single screen), and
/// the app doesn't take the focus either.
@MainActor
enum DebugLaunch {
    private static let selfTestKeys = ["GITCOWORK_SELFTEST", "GITCOWORK_UNDO_SELFTEST", "GITCOWORK_ACTIONS_SELFTEST"]

    static var isSelfTest: Bool {
        let env = ProcessInfo.processInfo.environment
        return selfTestKeys.contains { env[$0] != nil }
    }

    static var isSnapshot: Bool { ProcessInfo.processInfo.environment["GITCOWORK_SNAPSHOT"] != nil }

    /// Whether launching should leave the focus where it is.
    static var staysInBackground: Bool { isSelfTest || isSnapshot }

    /// Call instead of the usual activation, in applicationDidFinishLaunching.
    static func start() {
        if isSelfTest {
            // No Dock icon, and the app can't become active.
            NSApp.setActivationPolicy(.prohibited)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
        guard staysInBackground else { return }
        // SwiftUI opens its windows after launch, and more as tabs restore:
        // deal with each one as it shows up.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { placeWindows() }
        }
    }

    private static var observer: NSObjectProtocol?
    private static var placed = Set<ObjectIdentifier>()

    /// A repository window, before it is first shown (from WindowAccessor).
    static func windowWillShow(_ window: NSWindow) {
        guard staysInBackground else { return }
        placed.insert(ObjectIdentifier(window))
        if isSelfTest {
            window.alphaValue = 0
            DispatchQueue.main.async { window.orderOut(nil) }
        } else {
            moveAway(window)
            // SwiftUI may still put it where it was last time: once more after it showed.
            DispatchQueue.main.async { moveAway(window) }
        }
    }

    /// Windows that don't come through windowWillShow, like Settings.
    private static func placeWindows() {
        for window in NSApp.windows where window.isVisible && !placed.contains(ObjectIdentifier(window)) {
            placed.insert(ObjectIdentifier(window))
            if isSelfTest {
                window.orderOut(nil)
            } else if !window.isSheet, window.parent == nil {
                moveAway(window)
            }
        }
    }

    /// Onto a screen without the mouse pointer, fitted to it; with one screen,
    /// behind everything else.
    private static func moveAway(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { !NSMouseInRect(mouse, $0.frame, false) }) else {
            window.orderBack(nil)
            return
        }
        let area = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, area.width)
        frame.size.height = min(frame.height, area.height)
        frame.origin.x = area.midX - frame.width / 2
        frame.origin.y = area.midY - frame.height / 2
        window.setFrame(frame, display: true)
        window.orderBack(nil)
    }
}

#endif
