/// Options passed to every git command the app runs.
public enum GitDefaults {
    /// `-c` overrides beat any config in the repository, so a repo someone
    /// shares with you can't use them to run commands on its own.
    public static let configArgs: [String] = [
        "-c", "core.quotepath=false",   // paths as plain UTF-8
        "-c", "color.ui=false",         // output gets parsed, not shown raw
        // core.fsmonitor names a program git runs on every `git status`. The app
        // runs status by itself (on open, on file changes), so a repo's own
        // config could otherwise run code just by being opened. It's only a
        // speed-up, so turning it off changes no results.
        "-c", "core.fsmonitor=false",
        // An HTTPS transfer that stalls (no byte for a minute) fails instead of
        // hanging; a slow but moving one goes on.
        "-c", "http.lowSpeedLimit=1",
        "-c", "http.lowSpeedTime=60",
    ]

    /// Longest a command that talks to a server may run before it is stopped,
    /// so a hanging connection (SSH, a server that never answers) can't block
    /// the repository's actions forever. Clone has none: a big repository may
    /// take long. Local commands have none either.
    public static func timeout(for args: [String]) -> Double? {
        guard let command = args.first(where: { !$0.hasPrefix("-") }) else { return nil }
        switch command {
        case "ls-remote": return 60
        case "fetch", "pull", "push": return 600
        default: return nil
        }
    }
}
