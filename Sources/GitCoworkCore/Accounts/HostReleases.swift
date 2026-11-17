import Foundation

/// Creating a release for a tag (GitHub, GitLab, Gitea/Forgejo). Builds the
/// request and reads the answer; the app does the actual networking.
extension HostAPI {
    /// GitLab has no drafts or pre-releases.
    public static func releaseHasDraftAndPrerelease(_ kind: HostKind) -> Bool { kind != .gitlab }

    /// A release for `tag`, which must already be on the server.
    public static func createReleaseRequest(kind: HostKind, host: String, path: String, token: String, tag: String,
                                            title: String, notes: String, draft: Bool, prerelease: Bool) -> URLRequest? {
        guard let url = apiURL(kind: kind, host: host, path: path, suffix: "/releases") else { return nil }
        var body: [String: Any] = ["tag_name": tag, "name": title]
        switch kind {
        case .github, .gitea:
            body["body"] = notes
            body["draft"] = draft
            body["prerelease"] = prerelease
        case .gitlab:
            body["description"] = notes
        }
        var r = authorized(url, kind: kind, token: token)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    public enum CreateReleaseResult: Equatable, Sendable {
        /// The release's page, if the answer has one.
        case created(URL?)
        /// The tag has a release already.
        case alreadyExists
        case signedOut
        case failed(String)
    }

    /// Reads the answer to `createReleaseRequest`. The host's own message says
    /// what's wrong ("Release already exists").
    public static func parseCreatedRelease(status: Int, data: Data, kind: HostKind) -> CreateReleaseResult {
        if status == 401 { return .signedOut }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // GitHub says only "Validation Failed", with the reason as a code;
        // GitLab and Gitea answer 409 Conflict.
        let codes = (obj?["errors"] as? [[String: Any]])?.compactMap { $0["code"] as? String } ?? []
        if status == 409 || (status == 422 && codes.contains("already_exists")) { return .alreadyExists }
        guard (200..<300).contains(status) else { return .failed(errorMessage(data) ?? "HTTP \(status)") }
        let page: String? = switch kind {
        case .github, .gitea: obj?["html_url"] as? String
        case .gitlab: (obj?["_links"] as? [String: Any])?["self"] as? String
        }
        return .created(page.flatMap(webURL))
    }
}

/// What a new release is called and says, before the user changes it.
public enum ReleaseDraft {
    /// The next patch version after the newest version tag, keeping its
    /// "v": v0.6.3 → v0.6.4. Nil when no tag is a version.
    public static func nextTag(after tags: [String]) -> String? {
        let versions = tags.compactMap { tag in SemanticVersion(tag).map { (tag, $0) } }
            .filter { $0.1.prerelease.isEmpty }
        guard let (tag, newest) = versions.max(by: { $0.1 < $1.1 }) else { return nil }
        let prefix = tag.first.map { $0 == "v" || $0 == "V" ? String($0) : "" } ?? ""
        return "\(prefix)\(newest.major).\(newest.minor).\(newest.patch + 1)"
    }

    /// One line per commit, oldest first: "- Fix the tab bar".
    public static func notes(subjects: [String]) -> String {
        subjects.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { "- " + $0 }.joined(separator: "\n")
    }
}
