import Foundation
import Testing
import CoworkKit
@testable import GitCoworkCore

/// A newer version may add header fields (e.g. the repositories a task
/// belongs to). Editing with this version must write them back unchanged.
@Suite struct UnknownFieldsTests {
    let taskText = """
    ---
    id: CW-ab12
    title: Login page
    status: todo
    assignee: ""
    branch: ""
    repos: [github.com/org/frontend, github.com/org/backend]
    labels: [web]
    author: a@x.com
    created: 2026-11-01T10:00:00Z
    updated: 2026-11-01T10:00:00Z
    future: "some value"
    ---

    Shared between both repositories.
    """

    @Test func taskKeepsUnknownFields() throws {
        let t = try #require(CoworkCodec.decodeTask(taskText, id: "CW-ab12"))
        #expect(t.repos == ["github.com/org/frontend", "github.com/org/backend"], "known since multi-repository tasks")
        #expect(t.extra["future"] == .string("some value"))
        #expect(t.extra["title"] == nil && t.extra["labels"] == nil && t.extra["repos"] == nil, "known fields aren't extra")
        let again = try #require(CoworkCodec.decodeTask(CoworkCodec.encode(t), id: "CW-ab12"))
        #expect(again == t)
    }

    @Test func editingATaskKeepsThem() throws {
        let write = CoworkEdit.updateTasks(["CW-ab12": { $0.status = .doing; $0.title = "Login page v2" }], message: "edit")
        let out = write.build([CoworkPaths.task("CW-ab12"): taskText])
        let text = try #require(out[CoworkPaths.task("CW-ab12")] ?? nil)
        let doc = FrontMatter.parse(text)
        #expect(doc.list("repos") == ["github.com/org/frontend", "github.com/org/backend"])
        #expect(doc["future"] == "some value")
        #expect(doc["status"] == "doing" && doc["title"] == "Login page v2")
        #expect(doc.body == "Shared between both repositories.")
    }

    @Test func reviewsAndCommentsKeepThem() throws {
        let review = """
        ---
        id: R-1
        title: Login
        state: open
        branch: feat/login
        base: main
        requester: a@x.com
        reviewers: [b@x.com=requested]
        repo: github.com/org/frontend
        created: 2026-11-01T10:00:00Z
        updated: 2026-11-01T10:00:00Z
        ---
        """
        let r = try #require(CoworkCodec.decodeReview(review, id: "R-1"))
        #expect(FrontMatter.parse(CoworkCodec.encode(r))["repo"] == "github.com/org/frontend")

        let comment = "---\nauthor: a@x.com\nname: Anna\ncreated: 2026-11-01T10:00:00Z\nedited: yes\n---\n\nHi\n"
        let c = try #require(CoworkCodec.decodeComment(comment, id: "c1", parent: "tasks/CW-ab12"))
        #expect(FrontMatter.parse(CoworkCodec.encode(c))["edited"] == "yes")
    }

    @Test func mergeKeepsAFieldAddedOnOneSide() throws {
        // One person (newer version) adds a repository, another (this
        // version) changes the title at the same time: both survive.
        let base = taskText.replacingOccurrences(of: "repos: [github.com/org/frontend, github.com/org/backend]\n", with: "repos: [github.com/org/frontend]\n")
        let ours = taskText
        var t = try #require(CoworkCodec.decodeTask(base, id: "CW-ab12"))
        t.title = "Renamed"
        t.updated = CoworkCodec.date("2026-11-02T10:00:00Z")!
        let theirs = CoworkCodec.encode(t)
        let merged = try #require(CoworkMerge.mergeFile(path: CoworkPaths.task("CW-ab12"), base: base, ours: ours, theirs: theirs))
        let doc = FrontMatter.parse(merged)
        #expect(doc.list("repos") == ["github.com/org/frontend", "github.com/org/backend"])
        #expect(doc["title"] == "Renamed")
    }

    @Test func tasksWithoutExtraFieldsAreWrittenAsBefore() throws {
        let t = CoworkTask(id: "CW-1", title: "T", author: "a@x", created: CoworkCodec.date("2026-01-01T00:00:00Z")!,
                           updated: CoworkCodec.date("2026-01-01T00:00:00Z")!)
        #expect(CoworkCodec.encode(t) == """
        ---
        id: CW-1
        title: T
        status: backlog
        assignee: ""
        branch: ""
        labels: []
        author: a@x
        created: 2026-01-01T00:00:00Z
        updated: 2026-01-01T00:00:00Z
        ---

        """)
    }
}
