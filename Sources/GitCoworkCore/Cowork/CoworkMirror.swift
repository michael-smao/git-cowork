import Foundation

/// Which repository a task belongs to, the same on every computer: the
/// remote's host and path ("github.com/org/frontend"), lowercased, without
/// ".git". A remote that is a folder on disk is "file:" plus its path
/// (lowercased too: ids are compared as they are).
public enum RepoID {
    public static func of(remoteURL: String) -> String? {
        let url = remoteURL.trimmingCharacters(in: .whitespaces)
        if let links = RemoteLinks(remoteURL: url) { return "\(links.host)/\(links.path)".lowercased() }
        var path = url.hasPrefix("file://") ? String(url.dropFirst(7)) : url
        guard path.hasPrefix("/") else { return nil }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        return ("file:" + (path as NSString).standardizingPath).lowercased()
    }

    /// "frontend" for "github.com/org/frontend".
    public static func name(_ id: String) -> String {
        String(id.split(separator: "/").last ?? Substring(id))
    }
}

/// Keeps the copies of shared tasks in step. A task shared between several
/// repositories (`CoworkTask.repos`) is stored in each of them; whoever has
/// more than one of them open makes them agree:
///
/// - The newest copy (by `updated`) wins and is written where it differs.
/// - It goes to every repository in its `repos` list, and is removed from
///   one that was taken off the list.
/// - Comments are files of their own: every copy gets all of them.
/// - A shared task deleted somewhere leaves a marker (`deleted/<id>.md`).
///   If the marker is newer than every copy, the task is deleted everywhere;
///   if someone edited it after that, the edit wins and it comes back.
///
/// Repositories nobody here has open are left alone; someone who has them
/// does the same later.
public enum CoworkMirror {
    public struct Repo: Sendable {
        public var id: String
        public var snapshot: CoworkSnapshot

        public init(id: String, snapshot: CoworkSnapshot) {
            self.id = id
            self.snapshot = snapshot
        }
    }

    /// File changes per repository id (path -> text, nil deletes).
    public static func changes(_ input: [Repo], now: Date = Date(), me: String = "") -> [String: [String: String?]] {
        // As stored: an edit not saved yet has a date with fractions of a
        // second, its file doesn't. Compared as files, the result settles.
        let repos = input.map { r -> Repo in
            var r = r
            r.snapshot.tasks = r.snapshot.tasks.map { CoworkCodec.decodeTask(CoworkCodec.encode($0), id: $0.id) ?? $0 }
            return r
        }
        var out: [String: [String: String?]] = [:]
        // Tasks that are shared somewhere, or deleted while shared.
        var ids = Set<String>()
        for r in repos {
            for t in r.snapshot.tasks where !t.repos.isEmpty { ids.insert(t.id) }
        }
        for id in ids.sorted() {
            let copies = repos.compactMap { r in r.snapshot.task(id: id).map { (repo: r, task: $0) } }
            guard let winner = copies.max(by: { newer($1.task, than: $0.task) })?.task else { continue }
            let marker = repos.compactMap { $0.snapshot.deleted[id] }.max()
            let parent = winner.commentParent

            if let marker, marker >= winner.updated {
                // Deleted after the last edit: gone everywhere.
                for (repo, task) in copies {
                    var c: [String: String?] = [task.path: nil]
                    for comment in repo.snapshot.comments[parent] ?? [] { c[comment.path] = .some(nil) }
                    if repo.snapshot.deleted[id] == nil { c[CoworkPaths.deletedTask(id)] = CoworkCodec.encodeDeleted(at: marker, by: me) }
                    out[repo.id, default: [:]].merge(c) { $1 }
                }
                continue
            }

            // Every comment any copy has, by file name.
            var allComments: [String: CoworkComment] = [:]
            for (repo, _) in copies {
                for comment in repo.snapshot.comments[parent] ?? [] where allComments[comment.id] == nil {
                    allComments[comment.id] = comment
                }
            }
            // No list any more: it stays only where the newest copy is.
            let wanted = winner.repos.isEmpty
                ? Set(copies.filter { $0.task == winner }.map { $0.repo.id.lowercased() })
                : Set(winner.repos.map { $0.lowercased() })
            for repo in repos {
                let mine = repo.snapshot.task(id: id)
                var c: [String: String?] = [:]
                if wanted.contains(repo.id.lowercased()) {
                    if mine.map(CoworkCodec.encode) != CoworkCodec.encode(winner) { c[winner.path] = CoworkCodec.encode(winner) }
                    let have = Set((repo.snapshot.comments[parent] ?? []).map(\.id))
                    for (cid, comment) in allComments where !have.contains(cid) { c[comment.path] = CoworkCodec.encode(comment) }
                } else if let mine {
                    // Taken off the list: no longer on this repository's board.
                    c[mine.path] = .some(nil)
                    for comment in repo.snapshot.comments[parent] ?? [] { c[comment.path] = .some(nil) }
                }
                if !c.isEmpty { out[repo.id, default: [:]].merge(c) { $1 } }
            }
        }
        return out
    }

    /// The later edit; the same time sorts by content, so every computer picks the same copy.
    static func newer(_ a: CoworkTask, than b: CoworkTask) -> Bool {
        if a.updated != b.updated { return a.updated > b.updated }
        return CoworkCodec.encode(a) > CoworkCodec.encode(b)
    }
}
