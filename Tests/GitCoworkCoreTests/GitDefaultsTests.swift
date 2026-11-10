import Foundation
import Testing
@testable import GitCoworkCore

/// A repository whose own config sets core.fsmonitor to a script must not get
/// that script run when the app calls `git status`.
@Suite struct GitDefaultsTests {
    @Test func onlyServerCommandsTimeOut() {
        #expect(GitDefaults.timeout(for: ["fetch", "--prune", "origin"]) == 600)
        #expect(GitDefaults.timeout(for: ["push", "-u", "origin", "main"]) == 600)
        #expect(GitDefaults.timeout(for: ["ls-remote", "origin"]) == 60)
        #expect(GitDefaults.timeout(for: ["clone", "url", "dir"]) == nil)
        #expect(GitDefaults.timeout(for: ["status", "--porcelain"]) == nil)
        // A branch named "push" isn't a push.
        #expect(GitDefaults.timeout(for: ["switch", "push"]) == nil)
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    @Test func repoFsmonitorDoesNotRun() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gc-fsmonitor-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try git(["init", "-q"], in: dir)
        let marker = dir.appendingPathComponent("ran")
        let hook = dir.appendingPathComponent("monitor.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try git(["config", "core.fsmonitor", hook.path], in: dir)

        // Sanity check: plain git does run it, so the test can tell the difference.
        try git(["status", "--porcelain"], in: dir)
        #expect(fm.fileExists(atPath: marker.path))
        try fm.removeItem(at: marker)

        // With the app's options it doesn't.
        #expect(try git(GitDefaults.configArgs + ["status", "--porcelain"], in: dir) == 0)
        #expect(!fm.fileExists(atPath: marker.path))
    }
}
