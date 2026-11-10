import Foundation

/// Patterns for `.gitignore`, and adding them to the file's text.
public enum GitIgnore {
    /// Matches exactly this file (a path from the repository root).
    public static func pattern(forFile path: String) -> String {
        "/" + escape(path)
    }

    /// Matches everything inside this folder (a path from the repository root).
    public static func pattern(forFolder path: String) -> String {
        "/" + escape(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) + "/"
    }

    /// Matches every file with the same extension, in any folder: "*.log".
    /// Nil for a file without one (also ".env", whose dot starts the name).
    public static func pattern(forExtensionOf path: String) -> String? {
        let ext = fileExtension(path)
        return ext.isEmpty ? nil : "*." + escape(ext)
    }

    /// "log" for "build/out.log"; empty without an extension.
    public static func fileExtension(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    /// The folder a file is in ("build" for "build/out.log"); nil at the root.
    public static func folder(of path: String) -> String? {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return nil }
        return String(path[..<slash])
    }

    /// Backslash before what `.gitignore` reads as a wildcard, and before
    /// trailing spaces (git drops those otherwise).
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 4)
        for c in s {
            if c == "\\" || c == "*" || c == "?" || c == "[" { out.append("\\") }
            out.append(c)
        }
        var trailing = 0
        while out.hasSuffix(" ") { out.removeLast(); trailing += 1 }
        return out + String(repeating: "\\ ", count: trailing)
    }

    /// `contents` with each of `patterns` on a line of its own at the end.
    /// Patterns the file already has are left out. Keeps the file's line
    /// endings (CRLF stays CRLF).
    public static func adding(_ patterns: [String], to contents: String) -> String {
        let newline = contents.contains("\r\n") ? "\r\n" : "\n"
        var seen = Set(contents.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        var out = contents
        // "\r\n" is one Character, so look at the last byte instead of hasSuffix("\n").
        if !out.isEmpty, out.utf8.last != 0x0A { out += newline }
        for pattern in patterns where seen.insert(pattern).inserted {
            out += pattern + newline
        }
        return out
    }
}
