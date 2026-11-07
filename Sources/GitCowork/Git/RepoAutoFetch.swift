import AppKit
import Foundation
import GitCoworkCore
import Observation

/// Background `git fetch --all --prune` for one repo window: shortly after it
/// opens, then every 5 minutes while the app is in front (when it's due is
/// decided in GitCoworkCore's AutoFetch). Does nothing in the background.
@MainActor @Observable
final class RepoAutoFetch {
    /// Set while the background fetch runs. User actions wait for it briefly
    /// so two fetches don't fight over the same ref locks.
    private(set) var running = false
    /// Why background fetching stopped (a sign-in problem), with git's message.
    /// Cleared by the next fetch, pull or push that works.
    private(set) var paused: String?

    @ObservationIgnored weak var model: RepoModel?
    /// Signed-in accounts when the pause started. Signing in under Settings ›
    /// Accounts changes them and ends the pause.
    @ObservationIgnored private var accountsAtPause: [HostAccount] = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let openedAt = Date()

    /// Last fetch per repository (keyed by the shared .git folder), so two
    /// windows on worktrees of the same repo don't both fetch.
    private static var lastFetchByRepo: [String: Date] = [:]

    private var fetchKey: String? { model.map { $0.commonDir?.path ?? $0.root.path } }

    /// Last fetch from anywhere: this app, or the terminal (FETCH_HEAD's date).
    private var lastFetch: Date? {
        let fetchHead = model?.gitDir.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.appendingPathComponent("FETCH_HEAD").path)[.modificationDate] as? Date
        }
        return [fetchKey.flatMap { Self.lastFetchByRepo[$0] }, fetchHead].compactMap { $0 }.max()
    }

    /// Wakes on the same 30 s tick as the task sync. The loop never keeps the
    /// window alive: it only holds `self` (and the model) during a tick.
    func start() {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AutoFetch.firstDelay))
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(AutoFetch.tick))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Records a fetch (or pull/push) the user ran, so the timer starts over
    /// and a sign-in pause ends once it worked.
    func note(fetched: Bool, succeeded: Bool) {
        if fetched, let fetchKey { Self.lastFetchByRepo[fetchKey] = Date() }
        if succeeded { paused = nil }
    }

    /// Waits up to 15 s for a running background fetch, then goes ahead anyway.
    func waitUntilIdle() async {
        var waited = 0
        while running && waited < 150 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
    }

    private func tick() async {
        guard let model else { return }
        if paused != nil, AccountStore.shared.accounts != accountsAtPause { paused = nil }
        let conditions = AutoFetch.Conditions(
            enabled: Prefs.autoFetch, appActive: NSApp.isActive, hasRemotes: !model.remotes.isEmpty,
            actionRunning: model.busy != nil || running, pausedForSignIn: paused != nil,
            openedAt: openedAt, lastFetch: lastFetch)
        if AutoFetch.isDue(conditions, now: Date()) { await fetch(model) }
    }

    private func fetch(_ model: RepoModel) async {
        running = true
        defer { running = false }
        if let fetchKey { Self.lastFetchByRepo[fetchKey] = Date() }
        // Never ask for credentials: no terminal prompt (GitRunner sets it for
        // every command, repeated here because it matters most), no Git
        // Credential Manager window, no ssh-askpass dialog.
        let quiet = ["GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never", "SSH_ASKPASS_REQUIRE": "never"]
        do {
            try await model.git.run(["fetch", "--all", "--prune"], in: model.root, logged: true, env: quiet)
            guard !model.isStopped else { return }
            await model.refresh()
        } catch let error as GitError {
            if AutoFetch.classify(error.result.stderr) == .signIn {
                paused = error.localizedDescription
                accountsAtPause = AccountStore.shared.accounts
            }
            // Offline and other errors stay in the command log; the next tick retries.
        } catch {}
    }
}
