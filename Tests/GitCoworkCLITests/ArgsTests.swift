import Foundation
import Testing
import GitCoworkCLIKit
import GitCoworkCore

@Suite struct ArgsTests {
    @Test func titleWithoutQuotes() throws {
        let a = try Args(["new", "Fix", "login", "bug", "--label", "auth"])
        #expect(a.text(from: 1) == "Fix login bug")
        #expect(a.all("label") == ["auth"])
        try CommandSpec.check(a)
    }

    @Test func keyEqualsValueAndRepeats() throws {
        let a = try Args(["edit", "CW-1", "--label=a", "--label", "-b", "--title=Fix: x=y", "--json"])
        #expect(a.all("label") == ["a", "-b"])
        #expect(a.value("title") == "Fix: x=y")
        #expect(a.flag("json"))
        try CommandSpec.check(a)
    }

    @Test func unknownOptionsAreRejected() throws {
        #expect(throws: CLIError.usage("new doesn't take --asign")) { try CommandSpec.check(Args(["new", "x", "--asign", "me"])) }
        #expect(throws: CLIError.usage("list doesn't take --worktree")) { try CommandSpec.check(Args(["list", "--worktree"])) }
        #expect(throws: CLIError.self) { try Args(["new", "-x"]) }
        #expect(throws: CLIError.usage("--json doesn't take a value")) { try Args(["list", "--json=1"]) }
        #expect(throws: CLIError.usage("--to needs a value")) { try Args(["review", "b", "--to"]) }
        #expect(throws: CLIError.usage("unknown command frobnicate")) { try CommandSpec.check(Args(["frobnicate"])) }
    }

    @Test func extraWordsAreRejected() throws {
        #expect(throws: CLIError.usage("too many arguments for show: extra")) { try CommandSpec.check(Args(["show", "CW-1", "extra"])) }
        try CommandSpec.check(Args(["comment", "CW-1", "looks", "good"]))
        try CommandSpec.check(Args(["move", "CW-1", "done"]))
    }

    @Test func dashDashAndAliases() throws {
        let a = try Args(["add", "--", "-1", "is", "wrong"])
        #expect(a.text(from: 1) == "-1 is wrong")
        #expect(CommandSpec.canonical("ls") == "list" && CommandSpec.canonical("nope") == nil)
        let c = try Args(["-C", "/tmp", "list", "--mine"])
        #expect(c.value("C") == "/tmp" && c.positional == ["list"])
        try CommandSpec.check(c)
    }
}

@Suite struct PeopleTests {
    let known = [TeamMember(handle: "anna", name: "Anna", email: "anna@x.com"),
                 TeamMember(handle: "", name: "", email: "Ben@x.com"),
                 TeamMember(handle: "", name: "", email: "ben@y.com")]

    @Test func specialWordsAndEmails() throws {
        #expect(try People.resolve("me", me: "me@x.com", known: known) == "me@x.com")
        #expect(try People.resolve("none", me: "me@x.com", known: known) == nil)
        #expect(try People.resolve("carl@z.com", me: "", known: known) == "carl@z.com")
    }

    @Test func handles() throws {
        #expect(try People.resolve("Anna", me: "", known: known) == "anna@x.com")
        #expect(throws: CLIError.self) { try People.resolve("ben", me: "", known: known) }   // two Bens
        #expect(throws: CLIError.self) { try People.resolve("zoe", me: "", known: known) }
    }

    @Test func knownFromSnapshot() {
        var snap = CoworkSnapshot()
        snap.reviews = [ReviewRequest(id: "R-1", title: "", branch: "b", base: "main", requester: "r@x.com",
                                      reviewers: ["q@x.com": .requested], created: .now, updated: .now)]
        let emails = Set(People.known(in: snap).map(\.email))
        #expect(emails == ["r@x.com", "q@x.com"])
    }
}
