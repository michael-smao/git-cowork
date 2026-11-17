import Foundation
import Testing
@testable import GitCoworkCore

@Suite struct CoworkMirrorTests {
    let fe = "github.com/org/frontend", be = "github.com/org/backend", other = "github.com/org/other"
    let t0 = CoworkCodec.date("2026-11-01T10:00:00Z")!
    let t1 = CoworkCodec.date("2026-11-02T10:00:00Z")!
    let t2 = CoworkCodec.date("2026-11-03T10:00:00Z")!

    func task(_ title: String = "Login", repos: [String], updated: Date, status: TaskStatus = .todo) -> CoworkTask {
        var t = CoworkTask(id: "CW-ab12", title: title, status: status, author: "a@x.com", created: t0, updated: updated)
        t.repos = repos
        return t
    }

    func snap(_ tasks: [CoworkTask], comments: [CoworkComment] = [], deleted: [String: Date] = [:]) -> CoworkSnapshot {
        var s = CoworkSnapshot()
        s.tasks = tasks
        for c in comments { s.comments[c.parent, default: []].append(c) }
        s.deleted = deleted
        return s
    }

    func comment(_ id: String) -> CoworkComment {
        CoworkComment(id: id, parent: "tasks/CW-ab12", author: "a@x.com", authorName: "Anna", created: t0, body: id)
    }

    @Test func repoIDs() {
        #expect(RepoID.of(remoteURL: "git@github.com:Org/Frontend.git") == "github.com/org/frontend")
        #expect(RepoID.of(remoteURL: "https://github.com/org/frontend") == "github.com/org/frontend")
        #expect(RepoID.of(remoteURL: "ssh://git@gitlab.example.com:2222/group/sub/app.git") == "gitlab.example.com/group/sub/app")
        #expect(RepoID.of(remoteURL: "/tmp/x/../repos/App.git") == "file:/tmp/repos/app")
        #expect(RepoID.of(remoteURL: "relative/path") == nil)
        #expect(RepoID.name("github.com/org/frontend") == "frontend")
    }

    @Test func reposRoundTripAndOnlyWhenSet() throws {
        let shared = task(repos: [fe, be], updated: t0)
        #expect(CoworkCodec.decodeTask(CoworkCodec.encode(shared), id: shared.id)?.repos == [fe, be])
        #expect(!CoworkCodec.encode(task(repos: [], updated: t0)).contains("repos"))
    }

    @Test func addedRepoGetsACopyWithComments() {
        let a = CoworkMirror.Repo(id: fe, snapshot: snap([task(repos: [fe, be], updated: t1)], comments: [comment("c1")]))
        let b = CoworkMirror.Repo(id: be, snapshot: snap([]))
        let out = CoworkMirror.changes([a, b])
        #expect(out[fe] == nil, "the newest copy needs nothing")
        let toB = out[be] ?? [:]
        #expect(toB.keys.sorted() == ["tasks/CW-ab12.md", "tasks/CW-ab12/comments/c1.md"])
        #expect(CoworkCodec.decodeTask(toB["tasks/CW-ab12.md"]!!, id: "CW-ab12")?.repos == [fe, be])
    }

    @Test func newestEditWinsBothWays() {
        let a = CoworkMirror.Repo(id: fe, snapshot: snap([task("Old", repos: [fe, be], updated: t1)]))
        let b = CoworkMirror.Repo(id: be, snapshot: snap([task("New", repos: [fe, be], updated: t2, status: .doing)]))
        let out = CoworkMirror.changes([a, b])
        #expect(out[be] == nil)
        let written = out[fe]?["tasks/CW-ab12.md"] ?? nil
        #expect(CoworkCodec.decodeTask(written ?? "", id: "CW-ab12")?.title == "New")
        // Running it again on the result changes nothing.
        let a2 = CoworkMirror.Repo(id: fe, snapshot: snap([task("New", repos: [fe, be], updated: t2, status: .doing)]))
        #expect(CoworkMirror.changes([a2, b]).isEmpty)
    }

    @Test func commentsAreMerged() {
        let a = CoworkMirror.Repo(id: fe, snapshot: snap([task(repos: [fe, be], updated: t1)], comments: [comment("c1")]))
        let b = CoworkMirror.Repo(id: be, snapshot: snap([task(repos: [fe, be], updated: t1)], comments: [comment("c2")]))
        let out = CoworkMirror.changes([a, b])
        #expect(out[fe]?.keys.sorted() == ["tasks/CW-ab12/comments/c2.md"])
        #expect(out[be]?.keys.sorted() == ["tasks/CW-ab12/comments/c1.md"])
    }

    @Test func removedRepoLosesItsCopy() {
        let a = CoworkMirror.Repo(id: fe, snapshot: snap([task(repos: [fe], updated: t2)]))
        let b = CoworkMirror.Repo(id: be, snapshot: snap([task(repos: [fe, be], updated: t1)], comments: [comment("c1")]))
        let out = CoworkMirror.changes([a, b])
        // Comments written in backend stay with the task in frontend.
        #expect(out[fe]?.keys.sorted() == ["tasks/CW-ab12/comments/c1.md"])
        let toB = out[be] ?? [:]
        #expect(toB.keys.sorted() == ["tasks/CW-ab12.md", "tasks/CW-ab12/comments/c1.md"])
        #expect(toB.values.allSatisfy { $0 == nil }, "both deleted")
    }

    @Test func emptiedListKeepsTheTaskWhereItWasEdited() {
        let a = CoworkMirror.Repo(id: fe, snapshot: snap([task(repos: [], updated: t2)]))
        let b = CoworkMirror.Repo(id: be, snapshot: snap([task(repos: [fe, be], updated: t1)]))
        let out = CoworkMirror.changes([a, b])
        #expect(out[fe] == nil)
        #expect(out[be]?["tasks/CW-ab12.md"] == .some(nil))
    }

    @Test func deletionSpreadsUnlessEditedLater() {
        let b = CoworkMirror.Repo(id: be, snapshot: snap([task(repos: [fe, be], updated: t1)], comments: [comment("c1")]))
        // Deleted in frontend after the last edit: deleted in backend too, with a marker.
        let deleted = CoworkMirror.Repo(id: fe, snapshot: snap([], deleted: ["CW-ab12": t2]))
        let out = CoworkMirror.changes([deleted, b])
        #expect(out[fe] == nil)
        #expect(out[be]?["tasks/CW-ab12.md"] == .some(nil))
        #expect(out[be]?["tasks/CW-ab12/comments/c1.md"] == .some(nil))
        #expect(out[be]?["deleted/CW-ab12.md"] != nil)
        // Edited in backend after the delete: the edit wins and comes back.
        let edited = CoworkMirror.Repo(id: be, snapshot: snap([task(repos: [fe, be], updated: t2.addingTimeInterval(60))]))
        let back = CoworkMirror.changes([deleted, edited])
        #expect(back[fe]?["tasks/CW-ab12.md"] != nil)
        #expect(back[be] == nil)
    }

    @Test func reposNobodyHasOpenAreLeftAlone() {
        // Shared with "other" too, which isn't here: only the two present are touched.
        let a = CoworkMirror.Repo(id: fe, snapshot: snap([task(repos: [fe, be, other], updated: t1)]))
        let b = CoworkMirror.Repo(id: be, snapshot: snap([]))
        #expect(Set(CoworkMirror.changes([a, b]).keys) == [be])
    }

    @Test func tasksOfOneRepositoryAreNotTouched() {
        var plain = task(repos: [], updated: t1)
        plain.id = "CW-zz99"
        let a = CoworkMirror.Repo(id: fe, snapshot: snap([plain]))
        let b = CoworkMirror.Repo(id: be, snapshot: snap([]))
        #expect(CoworkMirror.changes([a, b]).isEmpty)
    }
}
