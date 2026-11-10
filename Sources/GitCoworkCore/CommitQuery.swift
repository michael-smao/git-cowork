import Foundation

/// What the history's search field holds. Plain words filter the commits
/// that are loaded (message, author, sha). Two terms ask git instead, over
/// the whole history of every branch:
///
///     file:Parsers        commits that changed a file whose path contains "Parsers"
///     change:"old name"   commits that added or removed that text (git log -S)
///
/// Both ignore case. Quotes keep a value with spaces together.
public struct CommitQuery: Hashable, Sendable {
    /// The plain words, lowercased, as typed (one space between them).
    public var text = ""
    public var file: String?
    public var change: String?

    public init(_ input: String) {
        var words: [Substring] = []
        var rest = Substring(input)
        while let start = rest.firstIndex(where: { !$0.isWhitespace }) {
            rest = rest[start...]
            if let term = Self.term(at: rest) {
                // A term without a value is still being typed: it filters nothing yet.
                if !term.value.isEmpty {
                    if term.isFile { file = term.value } else { change = term.value }
                }
                rest = term.rest
                continue
            }
            let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
            words.append(rest[..<end])
            rest = rest[end...]
        }
        text = words.joined(separator: " ").lowercased()
    }

    /// "file:" or "change:" at the start of `s`, with its value (quoted or up
    /// to the next space) and what follows it.
    private static func term(at s: Substring) -> (isFile: Bool, value: String, rest: Substring)? {
        let lower = s.prefix(7).lowercased()
        let isFile: Bool
        if lower.hasPrefix("file:") { isFile = true } else if lower.hasPrefix("change:") { isFile = false } else { return nil }
        var value = s.dropFirst(isFile ? 5 : 7)
        if value.first == "\"" {
            value = value.dropFirst()
            let end = value.firstIndex(of: "\"") ?? value.endIndex
            let rest = end == value.endIndex ? value[end...] : value[value.index(after: end)...]
            return (isFile, value[..<end].trimmingCharacters(in: .whitespaces), rest)
        }
        let end = value.firstIndex(where: \.isWhitespace) ?? value.endIndex
        return (isFile, String(value[..<end]), value[end...])
    }

    public var isEmpty: Bool { text.isEmpty && !searchesHistory }

    /// Has a `file:` or `change:` term: the commits come from `git log`
    /// (see `logOptions`, `logPathspecs`), not from the loaded ones.
    public var searchesHistory: Bool { file != nil || change != nil }

    /// Identifies the `git log` this query needs; equal keys give the same commits.
    public var historyKey: String? {
        searchesHistory ? "\(file ?? "")\u{1f}\(change ?? "")" : nil
    }

    /// Whether the plain words match a commit: its subject, the first line
    /// of its body, the author's name, or the start of its sha.
    public func matches(_ commit: Commit) -> Bool {
        text.isEmpty || commit.subject.lowercased().contains(text) || commit.authorName.lowercased().contains(text)
            || commit.id.hasPrefix(text) || commit.bodyPreview.lowercased().contains(text)
    }

    /// `git log` options for the `change:` term.
    public var logOptions: [String] {
        change.map { ["-i", "-S" + $0] } ?? []
    }

    /// `git log` pathspecs (after `--`) for the `file:` term: any path that
    /// contains the text. `*` and `?` in it stay wildcards.
    public var logPathspecs: [String] {
        guard let file else { return [] }
        var escaped = ""
        for c in file {
            if c == "\\" || c == "[" { escaped.append("\\") }
            escaped.append(c)
        }
        return [":(top,icase)*" + escaped + "*"]
    }
}
