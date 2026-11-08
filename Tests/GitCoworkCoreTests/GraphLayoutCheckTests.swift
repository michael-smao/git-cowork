import Foundation
import Testing
@testable import GitCoworkCore

/// Replays the drawn lines row by row and compares them with the commits'
/// parents, without using any of `GraphLayout`'s own reasoning. Returns what's
/// wrong; empty means every parent link is drawn and ends at the right commit.
private func problems(_ commits: [Commit], _ rows: [GraphRow]) -> [String] {
    guard commits.count == rows.count else { return ["\(commits.count) commits, \(rows.count) rows"] }
    var found: [String] = []
    var open: [Int: String] = [:]    // lane -> commit its line is heading for
    let loaded = Set(commits.map(\.id))

    for (commit, row) in zip(commits, rows) {
        func report(_ text: String) { found.append("\(commit.id): \(text)") }
        let incoming = row.lines.filter { $0.from == .top }
        let outgoing = row.lines.filter { $0.from == .middle }

        if row.lines.contains(where: { $0.from == .bottom || $0.to == .top }) { report("line runs upward") }
        if incoming.count != open.count || Set(incoming.map(\.fromLane)) != Set(open.keys) {
            report("lines from the row above aren't continued exactly once")
        }
        for line in incoming {
            guard let target = open[line.fromLane] else { report("line from an empty lane"); continue }
            if line.to == .middle {
                if target != commit.id || line.toLane != row.lane { report("line joins the wrong commit") }
            } else if target == commit.id || line.toLane != line.fromLane || line.to != .bottom {
                report("line passes its commit, or bends on the way")
            }
        }
        if incoming.contains(where: { $0.to == .bottom && $0.fromLane == row.lane }) {
            report("another line runs through this commit's dot")
        }
        for (lane, target) in open where target == commit.id { open[lane] = nil }

        if outgoing.count != commit.parents.count {
            report("\(outgoing.count) lines drawn for \(commit.parents.count) parents")
        }
        if let first = outgoing.first, first.toLane != row.lane { report("first parent left the lane") }
        for (line, parent) in zip(outgoing, commit.parents) {
            if line.fromLane != row.lane || line.to != .bottom { report("parent line starts elsewhere") }
            if let target = open[line.toLane], target != parent { report("parent line lands in another commit's lane") }
            open[line.toLane] = parent
        }
        if (row.lines.flatMap { [$0.fromLane, $0.toLane] } + [row.lane]).contains(where: { $0 >= row.laneCount }) {
            report("drawn wider than laneCount")
        }
    }
    for target in open.values where loaded.contains(target) { found.append("line never reached \(target)") }
    return found
}

private func commit(_ id: String, _ parents: [String]) -> Commit {
    Commit(id: id, parents: parents, authorName: "a", authorEmail: "a@x", date: .init(), subject: id)
}

/// Same seed, same history, so a failure can be reproduced.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {   // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A history with branches, merges, octopus merges and several roots, newest
/// first like `git log`.
private func randomHistory(seed: UInt64, size: Int) -> [Commit] {
    var random = SeededRandom(state: seed)
    var oldestFirst: [Commit] = []
    for i in 0..<size {
        let roll = Int.random(in: 0..<100, using: &random)
        let wanted = i == 0 || roll < 3 ? 0 : roll < 70 ? 1 : roll < 95 ? 2 : 3
        var parents: [String] = []
        for _ in 0..<wanted {
            // Mostly recent commits, sometimes an old one (a long-lived branch).
            let reach = Int.random(in: 0..<100, using: &random) < 80 ? min(i, 6) : i
            let parent = oldestFirst[i - 1 - Int.random(in: 0..<reach, using: &random)].id
            if !parents.contains(parent) { parents.append(parent) }
        }
        oldestFirst.append(commit("c\(i)", parents))
    }
    return oldestFirst.reversed()
}

@Suite struct GraphLayoutCheckTests {
    @Test func everyParentLinkIsDrawnInRandomHistories() {
        for seed in 1...300 as ClosedRange<UInt64> {
            let history = randomHistory(seed: seed, size: Int(seed % 120) + 2)
            let wrong = problems(history, GraphLayout.layout(history))
            #expect(wrong.isEmpty, "seed \(seed): \(wrong.prefix(3))")
        }
    }

    /// The app loads a limited number of commits, so parents can be missing.
    @Test func cutOffHistoryStaysCorrect() {
        for seed in 1...100 as ClosedRange<UInt64> {
            let history = Array(randomHistory(seed: seed, size: 150).prefix(Int(seed % 100) + 20))
            let wrong = problems(history, GraphLayout.layout(history))
            #expect(wrong.isEmpty, "seed \(seed): \(wrong.prefix(3))")
        }
    }

    /// A check that can't fail proves nothing: break a good graph and expect it noticed.
    @Test func theCheckCatchesBrokenGraphs() throws {
        let history = randomHistory(seed: 7, size: 200)
        let good = GraphLayout.layout(history)
        #expect(problems(history, good).isEmpty)

        func broken(at index: Int, _ change: (inout [GraphLine]) -> Void) -> [GraphRow] {
            var rows = good
            var lines = rows[index].lines
            change(&lines)
            rows[index] = GraphRow(lane: rows[index].lane, color: rows[index].color, lines: lines, laneCount: rows[index].laneCount)
            return rows
        }

        let merge = try #require(history.firstIndex { $0.parents.count > 1 })
        #expect(!problems(history, broken(at: merge) { $0.remove(at: $0.lastIndex { $0.from == .middle }!) }).isEmpty)

        let single = try #require(history.firstIndex { $0.parents.count == 1 })
        let lane = good[single].lane
        #expect(!problems(history, broken(at: single) {
            $0.append(GraphLine(fromLane: lane, from: .middle, toLane: lane + 1, to: .bottom, color: 0))
        }).isEmpty)

        let passing = try #require(good.firstIndex { $0.lines.contains { $0.from == .top && $0.to == .bottom } })
        #expect(!problems(history, broken(at: passing) { $0.remove(at: $0.firstIndex { $0.from == .top && $0.to == .bottom }!) }).isEmpty)
    }

    /// A real repository through real `git log`, read the way the app reads it.
    /// A cherry-pick copies a commit, so no line may connect it to the original;
    /// a real merge has to draw one.
    @Test func cherryPickStaysSeparateAndMergeConnects() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gc-graph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func git(_ args: String...) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = dir
            p.environment = [
                "PATH": "/usr/bin:/bin", "HOME": dir.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_AUTHOR_NAME": "a", "GIT_AUTHOR_EMAIL": "a@x", "GIT_COMMITTER_NAME": "a", "GIT_COMMITTER_EMAIL": "a@x",
            ]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            try #require(p.terminationStatus == 0, "git \(args.joined(separator: " "))")
            return String(decoding: data, as: UTF8.self)
        }
        func addCommit(_ name: String) throws {
            try name.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            _ = try git("add", name)
            _ = try git("commit", "-m", name)
        }
        func history() throws -> [Commit] {
            Parsers.parseLog(try git("log", "--date-order", "-n", "2000", Parsers.logFormat, "--branches", "--remotes", "--tags", "HEAD", "--"))
        }

        _ = try git("init", "-b", "main")
        try addCommit("base")
        _ = try git("checkout", "-b", "feature")
        try addCommit("first")
        try addCommit("second")
        _ = try git("checkout", "main")
        _ = try git("cherry-pick", "feature")

        let picked = try history()
        #expect(problems(picked, GraphLayout.layout(picked)).isEmpty)
        let base = try #require(picked.first { $0.subject == "base" })
        let first = try #require(picked.first { $0.subject == "first" })
        let copies = picked.filter { $0.subject == "second" }
        try #require(copies.count == 2)
        let copy = try #require(copies.first { $0.parents == [base.id] })
        let original = try #require(copies.first { $0.parents == [first.id] })
        #expect(copy.id != original.id)
        let copyRow = GraphLayout.layout(picked)[try #require(picked.firstIndex { $0.id == copy.id })]
        #expect(copyRow.lines.filter { $0.from == .middle }.count == 1)

        _ = try git("merge", "--no-ff", "-m", "merge", "feature")
        let merged = try history()
        #expect(problems(merged, GraphLayout.layout(merged)).isEmpty)
        let merge = try #require(merged.first { $0.subject == "merge" })
        #expect(merge.parents == [copy.id, original.id])
        let mergeRow = GraphLayout.layout(merged)[try #require(merged.firstIndex { $0.id == merge.id })]
        #expect(mergeRow.lines.filter { $0.from == .middle }.count == 2)
    }
}
