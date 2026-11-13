import Foundation

/// What went wrong when a git command failed, read from its error output, so
/// the app can say it in plain words and offer the obvious next step. Messages
/// are matched in English: the app runs git with LC_ALL=en_US.UTF-8.
public enum GitFailure: Equatable, Sendable {
    /// Push refused: the remote branch has commits this one doesn't.
    case pushRejected
    /// Push refused by the server's branch protection.
    case protectedBranch
    /// Push refused by another rule or hook on the server (a GitLab push rule
    /// such as signed commits, a GitHub ruleset, a pre-receive hook). `reason`
    /// is what the server said, empty when it said nothing.
    case serverRejected(reason: String)
    /// `--force-with-lease` refused: someone pushed since the last fetch.
    case staleLease
    /// Deleting a remote branch that is already gone there.
    case remoteRefMissing
    /// Pull without an upstream branch.
    case noUpstream
    /// Pull from an upstream that was deleted on the server.
    case upstreamGone
    /// Uncommitted changes to these files would be overwritten.
    case localChangesOverwritten(files: [String])
    /// Untracked files would be overwritten.
    case untrackedOverwritten(files: [String])
    /// The command refuses to run with uncommitted changes at all.
    case dirtyWorkingCopy
    /// The command stopped with conflicts for the user to resolve.
    case conflicts
    /// git doesn't know the user's name and email.
    case identityUnknown
    /// The server's SSH host key isn't known yet.
    case hostKeyUnknown
    /// Signed in, but the account may only read.
    case noWriteAccess
    /// The server wants credentials it didn't get.
    case signIn
    /// Offline, DNS, timeouts.
    case offline
    /// A branch, tag or folder of that name already exists.
    case alreadyExists
    /// Not a git repository, or one git refuses to use (ownership).
    case notARepository
    case other

    public static func classify(_ output: String) -> GitFailure {
        let s = output.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains(where: s.contains) }

        // Order matters: the more specific wording first.
        if has("stale info") { return .staleLease }
        // Only wording that names branch protection. "pre-receive hook declined"
        // alone doesn't: GitLab prints it for every refusal, push rules included.
        if has("protected branch", "gh006", "you are not allowed to force push") {
            return .protectedBranch
        }
        if has("[remote rejected]", "hook declined") { return .serverRejected(reason: remoteMessage(in: output)) }
        if has("[rejected]", "updates were rejected", "failed to push some refs") && has("fetch first", "non-fast-forward", "behind its remote") {
            return .pushRejected
        }
        if has("remote ref does not exist") { return .remoteRefMissing }
        if has("there is no tracking information", "has no upstream branch") { return .noUpstream }
        if has("no such ref was fetched", "couldn't find remote ref") { return .upstreamGone }
        if has("would be overwritten by") {
            let files = indentedFiles(after: "would be overwritten by", in: output)
            return has("untracked working tree files") ? .untrackedOverwritten(files: files) : .localChangesOverwritten(files: files)
        }
        if has("you have unstaged changes", "please commit or stash them", "cannot pull with rebase", "your index contains uncommitted changes") {
            return .dirtyWorkingCopy
        }
        if has("conflict (", "could not apply", "after resolving the conflicts", "fix conflicts and then",
               "automatic merge failed") {
            return .conflicts
        }
        if has("please tell me who you are", "author identity unknown", "empty ident name", "unable to auto-detect email address") {
            return .identityUnknown
        }
        if has("host key verification failed") { return .hostKeyUnknown }
        if has("permission to") && has("denied to") { return .noWriteAccess }
        if has("you are not allowed to push", "returned error: 403", "write access to repository not granted") {
            return .noWriteAccess
        }
        if CredentialConfig.isAuthFailure(output) || has("permission denied, please try again", "access denied", "returned error: 401") {
            return .signIn
        }
        if AutoFetch.classify(output) == .network { return .offline }
        if has("already exists") { return .alreadyExists }
        if has("not a git repository", "dubious ownership") { return .notARepository }
        return .other
    }

    /// What the server printed during a push (git shows those lines after
    /// "remote:"), without that prefix. The first few lines; all of it is in
    /// git's output anyway.
    static func remoteMessage(in output: String) -> String {
        let lines = output.split(separator: "\n").compactMap { line -> String? in
            // git pads these lines with spaces when it isn't writing to a terminal.
            var text = line.trimmingCharacters(in: .whitespaces)
            guard text.lowercased().hasPrefix("remote:") else { return nil }
            text = text.dropFirst("remote:".count).trimmingCharacters(in: .whitespaces)
            if text.lowercased().hasPrefix("error:") {
                text = text.dropFirst("error:".count).trimmingCharacters(in: .whitespaces)
            }
            return text.isEmpty ? nil : text
        }
        return lines.prefix(4).joined(separator: "\n")
    }

    /// The tab-indented file list git prints under "…would be overwritten by checkout:".
    static func indentedFiles(after marker: String, in output: String) -> [String] {
        var files: [String] = []
        var inList = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.lowercased().contains(marker) { inList = true; continue }
            guard inList else { continue }
            if line.hasPrefix("\t") || line.hasPrefix("    ") {
                let name = line.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { files.append(name) }
            } else if !files.isEmpty || !line.trimmingCharacters(in: .whitespaces).isEmpty {
                inList = false
            }
        }
        return files
    }
}
