import AppKit
import CoworkKit

/// git comes with Apple's Command Line Tools. A macOS update sometimes removes
/// them, and then every git call fails with "xcrun: error: invalid active
/// developer path". Spot that at launch and offer Apple's installer instead.
@MainActor
enum DeveloperToolsCheck {
    static func runAtLaunch() {
        // A git from Homebrew doesn't need the tools.
        guard GitRunner.shared.gitPath == "/usr/bin/git" else { return }
        Task {
            if await !toolsInstalled() { askToInstall() }
        }
    }

    /// `xcode-select -p` names the tools folder. Unlike running git, it
    /// doesn't trigger macOS's own install prompt when they're missing.
    nonisolated static func toolsInstalled() async -> Bool {
        let r = await Subprocess.run("/usr/bin/xcode-select", ["-p"], timeout: 10)
        return r.ok && FileManager.default.isExecutableFile(atPath: r.line + "/usr/bin/git")
    }

    private static func askToInstall() {
        let alert = NSAlert()
        alert.messageText = L("git-cowork needs Apple's developer tools")
        alert.informativeText = L("They include git. macOS sometimes removes them during an update. Installing them is free and takes a few minutes; git-cowork works again as soon as they're done.")
        alert.addButton(withTitle: L("Install"))
        alert.addButton(withTitle: L("Not Now"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Opens Apple's installer dialog.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["--install"]
        try? p.run()
    }
}
