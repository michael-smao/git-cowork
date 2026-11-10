import Foundation
import Testing
@testable import CoworkKit

@Suite struct SubprocessConcurrencyTests {
    /// More programs at once than GCD has worker threads (64), each writing
    /// to stderr: once they all waited on GCD for their stderr reader, which
    /// then never got a thread, and every later command hung.
    @Test(.timeLimit(.minutes(1))) func manyAtOnceAllFinish() async {
        let results = await withTaskGroup(of: GitOutput.self) { group in
            for i in 0..<150 {
                group.addTask {
                    await Subprocess.run("/bin/sh", ["-c", "echo out\(i); echo err\(i) >&2; sleep 0.2"])
                }
            }
            var all: [GitOutput] = []
            for await r in group { all.append(r) }
            return all
        }
        #expect(results.count == 150)
        #expect(results.allSatisfy { $0.exitCode == 0 && !$0.stderr.isEmpty && !$0.stdout.isEmpty })
    }

    @Test func passesInput() async {
        let r = await Subprocess.run("/bin/cat", [], input: Data("hello".utf8))
        #expect(String(decoding: r.stdout, as: UTF8.self) == "hello")
    }
}
