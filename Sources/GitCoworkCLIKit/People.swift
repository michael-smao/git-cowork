import Foundation
import GitCoworkCore

/// Turns what someone typed for a person (`--assign anna`, `--to ben@x.com`)
/// into the email stored in tasks and reviews.
public enum People {
    /// "me" -> `me`; "none", "nobody", "-" -> nil; anything with "@" stays as
    /// it is; otherwise a handle, which must belong to exactly one known person
    /// (team handle, or the part of an email before "@").
    public static func resolve(_ who: String, me: String, known: [TeamMember]) throws -> String? {
        let w = who.trimmingCharacters(in: .whitespaces)
        switch w.lowercased() {
        case "me": return me
        case "none", "nobody", "-": return nil
        default: break
        }
        if w.contains("@") { return w }
        guard !w.isEmpty else { throw CLIError.usage("missing a person (me, none, or an email)") }
        var matches: [String: String] = [:]   // lowercased email -> email
        for p in known where !p.email.isEmpty {
            let local = p.email.split(separator: "@").first.map(String.init) ?? ""
            if p.handle.caseInsensitiveCompare(w) == .orderedSame || local.caseInsensitiveCompare(w) == .orderedSame {
                matches[p.email.lowercased()] = matches[p.email.lowercased()] ?? p.email
            }
        }
        switch matches.count {
        case 1: return matches.values.first
        case 0: throw CLIError.failed("Nobody called \(w) here yet; use their email.")
        default: throw CLIError.failed("\(w) could be \(matches.values.sorted().joined(separator: " or ")); use the email.")
        }
    }

    /// Everyone the shared data knows: team members first, then everyone who
    /// wrote, was assigned, asked for or was asked for a review, or commented.
    public static func known(in snapshot: CoworkSnapshot) -> [TeamMember] {
        var people = snapshot.team
        var emails = snapshot.tasks.flatMap { [$0.author, $0.assignee].compactMap { $0 } }
        emails += snapshot.reviews.flatMap { [$0.requester] + Array($0.reviewers.keys) }
        emails += snapshot.comments.values.flatMap { $0.map(\.author) }
        for e in emails where !e.isEmpty {
            people.append(TeamMember(handle: "", name: "", email: e))
        }
        return people
    }
}
