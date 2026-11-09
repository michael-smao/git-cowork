import AppKit

/// Shows an alert as a sheet on the front window, never app-modal.
///
/// `NSAlert.runModal()` from a Task (after an `await`, as Check for Updates
/// does) could leave the alert off screen while its modal session still
/// blocked every window: the app beeped at clicks and showed nothing. A sheet
/// sits on a window you can see and blocks only that window.
@MainActor
enum AlertPresenter {
    @discardableResult
    static func show(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = hostWindow() else {
            // No window at all (everything closed): an app-modal alert is all there is.
            return alert.runModal()
        }
        window.makeKeyAndOrderFront(nil)
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    /// The front visible window that doesn't already show a sheet.
    private static func hostWindow() -> NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            + NSApp.orderedWindows.filter { $0.canBecomeMain }
        return candidates.first { $0.isVisible && $0.attachedSheet == nil && !$0.isSheet }
    }
}
