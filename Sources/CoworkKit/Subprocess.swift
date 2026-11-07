import Foundation
import GitCoworkCore

/// Runs a program and collects its output without blocking the caller:
/// the waiting happens on a GCD thread, never on Swift's cooperative pool.
/// Every process the app and the `git cowork` tool start goes through here.
public enum Subprocess {
    /// `env` nil inherits this process's environment. `timeout` stops the
    /// program (SIGTERM) when it runs longer; the result then says so in stderr.
    public static func run(_ executable: String, _ args: [String], input: Data? = nil, env: [String: String]? = nil,
                           dir: URL? = nil, timeout: TimeInterval? = nil) async -> GitOutput {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runBlocking(executable, args, input: input, env: env, dir: dir, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ executable: String, _ args: [String], input: Data?, env: [String: String]?,
                                    dir: URL?, timeout: TimeInterval?) -> GitOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = input.map { _ in Pipe() }
        p.standardInput = inPipe ?? FileHandle.nullDevice
        do { try p.run() } catch {
            return GitOutput(stdout: Data(), stderr: Data(error.localizedDescription.utf8), exitCode: -1)
        }
        if let inPipe, let input {
            // Write on another thread so a large input can't deadlock against the output.
            DispatchQueue.global(qos: .userInitiated).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let timedOut = TimedOut()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { timedOut.set(); p.terminate() }
            }
        }
        // Read both pipes at once so a full stderr buffer can't block the program.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        if timedOut.value, let timeout {
            errData += Data("\n\(URL(fileURLWithPath: executable).lastPathComponent) stopped after \(Int(timeout)) s.".utf8)
        }
        return GitOutput(stdout: outData, stderr: errData, exitCode: p.terminationStatus)
    }

    private final class TimedOut: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}

/// The environment and options every git command gets, in the app and the tool.
public enum GitEnvironment {
    /// `base` plus: fail instead of waiting for a password on a missing tty,
    /// no optional locks (`git status` must not touch the index, which would
    /// retrigger file watching), accept default messages instead of opening
    /// an editor, and English messages (some are matched, e.g. by AutoFetch).
    public static func make(_ base: [String: String]) -> [String: String] {
        var e = base
        e["GIT_TERMINAL_PROMPT"] = "0"
        e["GIT_OPTIONAL_LOCKS"] = "0"
        e["GIT_EDITOR"] = "true"
        e["GIT_MERGE_AUTOEDIT"] = "no"
        e["LC_ALL"] = "en_US.UTF-8"
        return e
    }

    /// `-c` options put before every git command (see GitDefaults).
    public static var configArgs: [String] { GitDefaults.configArgs }
}
