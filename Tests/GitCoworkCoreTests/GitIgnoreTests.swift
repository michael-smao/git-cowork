import Testing
@testable import GitCoworkCore

@Suite struct GitIgnoreTests {
    @Test func patternsAreAnchoredAtTheRoot() {
        #expect(GitIgnore.pattern(forFile: "build/out.log") == "/build/out.log")
        #expect(GitIgnore.pattern(forFolder: "build") == "/build/")
        #expect(GitIgnore.pattern(forFolder: "a/b/") == "/a/b/")
    }

    @Test func extensionPattern() {
        #expect(GitIgnore.pattern(forExtensionOf: "build/out.log") == "*.log")
        #expect(GitIgnore.pattern(forExtensionOf: "archive.tar.gz") == "*.gz")
        // No extension: a plain name, a dot file, a dot only in the folder.
        #expect(GitIgnore.pattern(forExtensionOf: "Makefile") == nil)
        #expect(GitIgnore.pattern(forExtensionOf: ".env") == nil)
        #expect(GitIgnore.pattern(forExtensionOf: "v1.2/notes") == nil)
    }

    @Test func folderOfAPath() {
        #expect(GitIgnore.folder(of: "a/b/c.txt") == "a/b")
        #expect(GitIgnore.folder(of: "c.txt") == nil)
    }

    @Test func escapesWildcardsAndTrailingSpaces() {
        #expect(GitIgnore.pattern(forFile: "notes [draft]*.txt") == "/notes \\[draft]\\*.txt")
        #expect(GitIgnore.pattern(forFile: "what?.md") == "/what\\?.md")
        #expect(GitIgnore.pattern(forFile: "back\\slash") == "/back\\\\slash")
        #expect(GitIgnore.pattern(forFile: "name  ") == "/name\\ \\ ")
        // "#" and "!" only mean something at the start of a line; ours start with "/".
        #expect(GitIgnore.pattern(forFile: "#notes") == "/#notes")
    }

    @Test func addsToAnEmptyOrMissingFile() {
        #expect(GitIgnore.adding(["/a.log"], to: "") == "/a.log\n")
        #expect(GitIgnore.adding(["/a.log", "*.tmp"], to: "") == "/a.log\n*.tmp\n")
    }

    @Test func addsAfterTheLastLine() {
        #expect(GitIgnore.adding(["/a.log"], to: "node_modules/\n") == "node_modules/\n/a.log\n")
        // No newline at the end of the file: add one first.
        #expect(GitIgnore.adding(["/a.log"], to: "node_modules/") == "node_modules/\n/a.log\n")
    }

    @Test func skipsPatternsAlreadyThere() {
        let before = "# build output\n/a.log\n  *.tmp  \n"
        #expect(GitIgnore.adding(["/a.log", "*.tmp"], to: before) == before)
        #expect(GitIgnore.adding(["/a.log", "/b.log", "/b.log"], to: before) == before + "/b.log\n")
    }

    @Test func keepsWindowsLineEndings() {
        #expect(GitIgnore.adding(["/a.log"], to: "x\r\ny\r\n") == "x\r\ny\r\n/a.log\r\n")
        #expect(GitIgnore.adding(["/a.log"], to: "x\r\ny") == "x\r\ny\r\n/a.log\r\n")
    }
}
