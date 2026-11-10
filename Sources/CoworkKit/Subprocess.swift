import Foundation
import GitCoworkCore

/// Runs a program and collects its output without blocking the caller:
/// the waiting happens on a thread of its own, never on Swift's cooperative
/// pool or GCD's. GCD has at most 64 worker threads: with that many commands
/// waiting on it (ten repositories loading at once), the stderr readers they
/// wait for got no thread, and every git command hung from then on.
/// Every process the app and the `git cowork` tool start goes through here.
public enum Subprocess {
    /// `env` nil inherits this process's environment. `timeout` stops the
    /// program (SIGTERM) when it runs longer; the result then says so in stderr.
    /// `cancellable` also stops it when the calling task is cancelled. Only
    /// for reads whose result nobody waits for anymore (a search typed over):
    /// a command that changes the repository must always run to its end.
    public static func run(_ executable: String, _ args: [String], input: Data? = nil, env: [String: String]? = nil,
                           dir: URL? = nil, timeout: TimeInterval? = nil, cancellable: Bool = false) async -> GitOutput {
        let stopper = cancellable ? Stopper() : nil
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                onOwnThread {
                    cont.resume(returning: runBlocking(executable, args, input: input, env: env, dir: dir,
                                                       timeout: timeout, stopper: stopper))
                }
            }
        } onCancel: {
            stopper?.stop()
        }
    }

    /// Blocking work (waiting for a program, reading its pipes) gets a thread
    /// of its own, so it can never wait for a pool thread that is itself waiting.
    private static func onOwnThread(_ work: @escaping @Sendable () -> Void) {
        let thread = Thread(block: work)
        thread.qualityOfService = .userInitiated
        thread.stackSize = 256 * 1024
        thread.start()
    }

    /// Stops a program when its task is cancelled, also when the cancellation
    /// comes before the program has started.
    private final class Stopper: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false

        /// Called once the program runs.
        func attach(_ p: Process) {
            lock.lock()
            process = p
            let stopNow = stopped
            lock.unlock()
            if stopNow, p.isRunning { p.terminate() }
        }

        func stop() {
            lock.lock()
            stopped = true
            let p = process
            lock.unlock()
            if let p, p.isRunning { p.terminate() }
        }
    }

    private static func runBlocking(_ executable: String, _ args: [String], input: Data?, env: [String: String]?,
                                    dir: URL?, timeout: TimeInterval?, stopper: Stopper? = nil) -> GitOutput {
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
        stopper?.attach(p)
        if let inPipe, let input {
            // Write on another thread so a large input can't deadlock against the output.
            onOwnThread {
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
        let errData = Collected()
        let group = DispatchGroup()
        group.enter()
        onOwnThread {
            errData.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        var stderr = errData.value
        if timedOut.value, let timeout {
            stderr += Data("\n\(URL(fileURLWithPath: executable).lastPathComponent) stopped after \(Int(timeout)) s.".utf8)
        }
        return GitOutput(stdout: outData, stderr: stderr, exitCode: p.terminationStatus)
    }

    /// stderr, read on its own thread.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
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
