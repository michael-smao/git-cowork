import Foundation

/// Remembers which changed paths git ignores, so file events from build
/// folders, dependencies and logs are dropped without running git again.
/// A build then costs one `git check-ignore`, not a refresh per batch of files.
///
/// What it holds is only as good as the ignore rules and the index it was
/// asked under: `forget()` whenever either may have changed.
public struct IgnoredPaths: Sendable {
    /// Ignored folders, each with a trailing "/", none inside another.
    private var folders: [String] = []
    /// Single paths git was asked about: true when ignored.
    private var paths: [String: Bool] = [:]

    private static let pathLimit = 4096
    private static let folderLimit = 256

    public init() {}

    public enum Answer: Equatable, Sendable {
        /// Ignored: a change there shows nowhere.
        case ignored
        /// Tracked, or new and not ignored: worth a refresh.
        case relevant
        /// Not asked yet.
        case unknown
    }

    public func answer(for path: String) -> Answer {
        if let known = paths[path] { return known ? .ignored : .relevant }
        if folders.contains(where: path.hasPrefix) { return .ignored }
        return .unknown
    }

    /// What to pass to `git check-ignore -z --stdin` to learn about `changed`
    /// (absolute paths inside the worktree at `root`): each path, and every
    /// folder above it with a trailing "/". The slash makes git treat it as a
    /// folder even when it is gone again, and a whole ignored folder is worth
    /// far more than one file in it.
    public static func questions(for changed: [String], under root: String) -> [String] {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var seen = Set<String>()
        var out: [String] = []
        for path in changed where path.hasPrefix(prefix) {
            var end = path.index(path.startIndex, offsetBy: prefix.count)
            while let slash = path[end...].firstIndex(of: "/") {
                end = path.index(after: slash)
                let folder = String(path[..<end])
                if seen.insert(folder).inserted { out.append(folder) }
            }
            if !path.hasSuffix("/"), seen.insert(path).inserted { out.append(path) }
        }
        return out
    }

    /// Takes in git's reply: `ignored` is the part of `asked` it printed back.
    public mutating func learn(asked: [String], ignored: [String]) {
        let hit = Set(ignored)
        // Shortest first, so a folder inside an ignored one isn't kept as well.
        for folder in hit.filter({ $0.hasSuffix("/") }).sorted(by: { $0.count < $1.count })
        where !folders.contains(where: folder.hasPrefix) {
            if folders.count >= Self.folderLimit { folders.removeAll() }
            folders.append(folder)
        }
        if paths.count + asked.count > Self.pathLimit { paths.removeAll() }
        for path in asked where !path.hasSuffix("/") {
            paths[path] = hit.contains(path)
        }
    }

    /// The ignore rules or the tracked files may have changed: ask again.
    public mutating func forget() {
        folders.removeAll()
        paths.removeAll()
    }

    public var isEmpty: Bool { folders.isEmpty && paths.isEmpty }
}

/// How soon a change on disk is shown. One save shows right away; while files
/// keep changing (a build, an agent at work) the repository is read at most
/// once per `gap`, so git doesn't run back to back for as long as that lasts.
public enum RefreshPacing {
    /// Lets the rest of a save arrive: editors write several files at once.
    public static let settle: TimeInterval = 0.15
    /// Between two reads while changes keep coming and the window is watched.
    public static let watchedGap: TimeInterval = 1
    /// The same when nobody looks: the app is behind, or the tab is.
    public static let unwatchedGap: TimeInterval = 3
    /// A slow repository gets a longer gap, up to this.
    public static let longestGap: TimeInterval = 15
    /// A read may take this share of the time.
    static let dutyCycle: Double = 0.25

    /// Seconds to wait before reading the repository after a file changed.
    /// - sinceLast: since the last such read started; nil when there was none.
    /// - lastDuration: how long that read took.
    /// - watched: the app is in front and this window's tab is showing.
    public static func wait(sinceLast: TimeInterval?, lastDuration: TimeInterval, watched: Bool) -> TimeInterval {
        guard let sinceLast else { return settle }
        let gap = min(longestGap, max(watched ? watchedGap : unwatchedGap, lastDuration / dutyCycle))
        return max(settle, gap - sinceLast)
    }
}
