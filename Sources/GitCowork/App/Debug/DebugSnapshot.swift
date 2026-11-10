import AppKit
import GitCoworkCore
import SwiftUI

// Debug builds only: lets developers and agents check the UI from a terminal.
// Release builds (make app / make install) don't contain any of this.
#if DEBUG

/// For checking the UI without screen-recording permission:
/// GITCOWORK_SNAPSHOT=/tmp/shot.png renders the front window (or its open sheet) to a PNG after a few seconds.
enum DebugSnapshot {
    /// GITCOWORK_DEBUG_SELECT = "commit:<n>" (nth commit) | "diff" (first changed file) | "commitdiff:<n>"
    ///   | "stash:<n>" (nth stash) | "stashdiff:<n>" (and its last file's diff)
    /// GITCOWORK_DEBUG_FILTER = text for the history's search field, e.g. "file:Login".
    /// GITCOWORK_DEBUG_SHEET = "addRemote" | "editRemote".
    /// GITCOWORK_DEBUG_MODE = "board" | "reviews", optionally ":<n>" to select the nth task / review.
    /// GITCOWORK_DEBUG_LOG = "1" opens the command log.
    @MainActor
    static func applySelection(_ model: RepoModel) async {
        applyMode(model)
        await applyHostDemo(model)
        // GITCOWORK_DEBUG_LOG = "1": open the command log.
        if ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_LOG"] != nil { model.showCommandLog = true }
        // GITCOWORK_DEBUG_GIT = "Label|git args": run it like a button would, to see how a failure is shown.
        if let run = ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_GIT"] {
            let parts = run.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 { await model.perform(parts[0], parts[1].split(separator: " ").map(String.init)) }
        }
        // GITCOWORK_DEBUG_COMMIT = "message": Stage All and Commit (shows the undo hint).
        if let message = ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_COMMIT"] {
            _ = await model.stageAllAndCommit(message: message)
        }
        // GITCOWORK_DEBUG_PUSH = "1": the toolbar's Push.
        if ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_PUSH"] != nil { await model.push() }
        // GITCOWORK_DEBUG_FILTER = "file:Login": what to put in the history's search field.
        if let filter = ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_FILTER"] { model.filterText = filter }
        // GITCOWORK_DEBUG_SHEET = "addRemote" | "editRemote" (the first remote): open that sheet.
        switch ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_SHEET"] {
        case "addRemote": model.sheet = .addRemote(thenPush: nil)
        case "editRemote": if let remote = model.remotes.first { model.sheet = .editRemote(remote.name) }
        default: break
        }
        guard let sel = ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_SELECT"] else { return }
        let parts = sel.split(separator: ":")
        let n = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        switch parts.first {
        case "commit":
            if n < model.commits.count { model.reveal(model.commits[n].id) }
        case "diff":
            if let f = (model.status.unstaged + model.status.staged).first { model.openDiff = .working(f) }
        case "commitdiff":
            guard n < model.commits.count, let d = await model.commitDetail(model.commits[n].id) else { return }
            model.reveal(d.id)
            if let f = await model.changedFiles(d).first { model.openDiff = .commit(d, f) }
        case "stash", "stashdiff":
            // The nth stash in the right panel; "stashdiff" also opens its last file.
            guard n < model.stashes.count else { return }
            let stash = model.stashes[n]
            model.selection = .stash(stash.sha)
            if parts.first == "stashdiff", let c = await model.stashContents(stash), let f = c.files.last {
                model.openDiff = .commit(c.source(of: f), f)
            }
        default: break
        }
    }

    /// GITCOWORK_DEBUG_HOST = "1": sample pull requests and CI on the repo's branches.
    /// "sheet" also opens Create Pull Request. No network, no account needed.
    @MainActor
    private static func applyHostDemo(_ model: RepoModel) async {
        guard let value = ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_HOST"] else { return }
        await model.updateHostStatus()
        guard let status = model.hostStatus else { debugLog("host demo: no known host on the remote"); return }
        let branches = model.localBranches.filter { $0.name != model.baseBranchName }
        let pulls = branches.prefix(3).enumerated().map { n, ref in
            HostPull(number: 12 + n, title: model.commit(ref.target)?.subject ?? ref.name, author: "anna", branch: ref.name, base: model.baseBranchName,
                     headSHA: ref.target, webURL: URL(string: "https://example.com/pull/\(12 + n)"), isDraft: n == 2, isFromFork: false)
        }
        let check = { (name: String, state: CIState) in CICheck(name: name, state: state, url: URL(string: "https://example.com/run")) }
        var ci: [String: CIResult] = [:]
        if let first = branches.first { ci[first.target] = CIResult(checks: [check("build", .success), check("test", .failure), check("lint", .success)]) }
        if branches.count > 1 { ci[branches[1].target] = CIResult(checks: [check("build", .pending), check("lint", .success)]) }
        if let base = model.branch(named: model.baseBranchName) { ci[base.target] = CIResult(checks: [check("build", .success)]) }
        status.showDemo(pulls: Array(pulls), ci: ci)
        if value == "sheet", let first = branches.last { model.sheet = .createPull(branch: first.name) }
    }

    @MainActor
    private static func applyMode(_ model: RepoModel) {
        guard let value = ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_MODE"] else { return }
        let parts = value.split(separator: ":")
        guard let mode = parts.first.flatMap({ CenterMode(rawValue: String($0)) }) else { return }
        model.centerMode = mode
        guard parts.count > 1, let n = Int(parts[1]) else { return }
        switch mode {
        case .board:
            if n < model.cowork.tasks.count { model.coworkSelection = .task(model.cowork.tasks[n].id) }
        case .reviews:
            if n < model.cowork.reviews.count { model.coworkSelection = .review(model.cowork.reviews[n].id) }
        case .history: break
        }
    }

    @MainActor
    static func scheduleIfRequested() {
        // GITCOWORK_DEBUG_APPEARANCE = "light" | "dark": render in that appearance.
        switch ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        // GITCOWORK_DEBUG_SETTINGS=1: open the Settings window (to snapshot it).
        if ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // Same as choosing git-cowork > Settings… (⌘,).
                guard let menu = NSApp.mainMenu?.items.first?.submenu,
                      let i = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
                menu.performActionForItem(at: i)
            }
        }
        // GITCOWORK_DEBUG_CLONE=1: open the Clone sheet in the first window (to snapshot it).
        if ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_CLONE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // Same as choosing File > Clone Repository… (⇧⌘O).
                for item in NSApp.mainMenu?.items ?? [] {
                    guard let menu = item.submenu,
                          let i = menu.items.firstIndex(where: { $0.title == L("Clone Repository…") }) else { continue }
                    menu.performActionForItem(at: i)
                    return
                }
            }
        }
        guard let path = ProcessInfo.processInfo.environment["GITCOWORK_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["GITCOWORK_SNAPSHOT_DELAY"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // The app usually isn't active when run from a terminal, so there's no key
            // window; take the selected tab of the frontmost window group.
            let settings = ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_SETTINGS"] == nil ? nil
                : NSApp.windows.first { $0.isVisible && (($0.identifier?.rawValue ?? "") + $0.title).localizedCaseInsensitiveContains("settings") }
            let candidate = settings ?? NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.contentView != nil })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
            let front = candidate?.tabGroup?.selectedWindow ?? candidate
            guard let window = front?.attachedSheet ?? front,
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                debugLog("snapshot: no visible window (\(NSApp.windows.count) windows)")
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            if ProcessInfo.processInfo.environment["GITCOWORK_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
        }
    }
}

func debugLog(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

#endif
