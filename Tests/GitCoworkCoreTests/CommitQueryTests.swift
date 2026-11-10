import Foundation
import Testing
@testable import GitCoworkCore

@Suite struct CommitQueryTests {
    private func commit(_ subject: String, author: String = "Anna", body: String = "",
                        id: String = "abc1234def") -> Commit {
        Commit(id: id, parents: [], authorName: author, authorEmail: "a@x.com", date: Date(timeIntervalSince1970: 0),
               subject: subject, bodyPreview: body)
    }

    @Test func plainWordsFilterLoadedCommits() {
        let q = CommitQuery("  Fix Login ")
        #expect(q.text == "fix login")
        #expect(!q.searchesHistory)
        #expect(q.historyKey == nil)
        #expect(q.matches(commit("Fix login on Safari")))
        #expect(!q.matches(commit("Add cache")))
        // Author, first body line and the start of the sha count too.
        #expect(CommitQuery("anna").matches(commit("x")))
        #expect(CommitQuery("details").matches(commit("x", body: "More details here")))
        #expect(CommitQuery("abc12").matches(commit("x")))
        #expect(!CommitQuery("c1234").matches(commit("x")))
    }

    @Test func emptyQueryMatchesEverything() {
        let q = CommitQuery("   ")
        #expect(q.isEmpty)
        #expect(q.matches(commit("anything")))
        #expect(q.logOptions.isEmpty)
        #expect(q.logPathspecs.isEmpty)
    }

    @Test func quotesInPlainTextStay() {
        // Searching a subject like: Revert "Add cache"
        let q = CommitQuery("revert \"add")
        #expect(q.text == "revert \"add")
        #expect(q.matches(commit("Revert \"Add cache\"")))
    }

    @Test func fileTerm() {
        let q = CommitQuery("file:Parsers")
        #expect(q.file == "Parsers")
        #expect(q.text.isEmpty)
        #expect(q.searchesHistory)
        #expect(!q.isEmpty)
        #expect(q.logOptions.isEmpty)
        #expect(q.logPathspecs == [":(top,icase)*Parsers*"])
    }

    @Test func changeTerm() {
        let q = CommitQuery("change:oldName")
        #expect(q.change == "oldName")
        #expect(q.logOptions == ["-i", "-SoldName"])
        #expect(q.logPathspecs.isEmpty)
    }

    @Test func quotedValuesKeepSpaces() {
        let q = CommitQuery("change:\"let x = 1\" FILE:\"My Notes.md\" fix")
        #expect(q.change == "let x = 1")
        #expect(q.file == "My Notes.md")
        #expect(q.text == "fix")
        // A quote that isn't closed yet takes the rest.
        #expect(CommitQuery("change:\"still typing").change == "still typing")
    }

    @Test func termsCombineWithPlainWords() {
        let q = CommitQuery("anna file:Views/History login")
        #expect(q.file == "Views/History")
        #expect(q.text == "anna login")
        #expect(q.matches(commit("Login screen", author: "Anna Lee")) == false)   // "anna login" isn't in one field
        #expect(CommitQuery("file:x login").matches(commit("Login screen")))
    }

    @Test func aTermWithoutValueIsStillBeingTyped() {
        let q = CommitQuery("file:")
        #expect(q.file == nil)
        #expect(q.isEmpty)
        #expect(!q.searchesHistory)
        #expect(CommitQuery("change:\"\"").change == nil)
    }

    @Test func wildcardsStayAndBracketsAreEscaped() {
        #expect(CommitQuery("file:*.swift").logPathspecs == [":(top,icase)**.swift*"])
        #expect(CommitQuery("file:a[1]").logPathspecs == [":(top,icase)*a\\[1]*"])
    }

    @Test func historyKeyTellsSearchesApart() {
        #expect(CommitQuery("file:a").historyKey == CommitQuery("file:a login").historyKey)
        #expect(CommitQuery("file:a").historyKey != CommitQuery("change:a").historyKey)
        #expect(CommitQuery("file:a").historyKey != CommitQuery("file:b").historyKey)
    }

    @Test func wordsThatOnlyLookLikeTerms() {
        // "profile:" isn't "file:", and a term in the middle of a word isn't one.
        let q = CommitQuery("profile:x")
        #expect(q.file == nil)
        #expect(q.text == "profile:x")
    }
}
