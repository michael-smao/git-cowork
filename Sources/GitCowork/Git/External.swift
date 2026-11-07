import AppKit
import Foundation

/// Opening things outside the app: editor, terminal, Finder, browser, clipboard.
enum External {
    /// Opens `path` with the app named in Settings ("Visual Studio Code", or a
    /// bundle id like "com.mitchellh.ghostty"). Beeps when there's no such app.
    static func open(app: String, path: String) {
        let target = URL(fileURLWithPath: path)
        guard let appURL = applicationURL(app, toOpen: target) else { NSSound.beep(); return }
        NSWorkspace.shared.open([target], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    /// "<name>.app" in the usual folders, else an app with that bundle id,
    /// else one of that name that macOS knows can open `target`.
    static func applicationURL(_ name: String, toOpen target: URL) -> URL? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let file = name.hasSuffix(".app") ? name : name + ".app"
        let folders = ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications",
                       "/System/Applications", "/System/Applications/Utilities"]
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
            ?? NSWorkspace.shared.urlsForApplications(toOpen: target).first { $0.lastPathComponent == file }
    }

    static func openTerminal(_ path: String) { open(app: Prefs.terminalApp, path: path) }
    static func openEditor(_ path: String) { open(app: Prefs.editorApp, path: path) }
    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    static func browse(_ url: URL?) { if let url { NSWorkspace.shared.open(url) } }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
