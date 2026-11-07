import Foundation

/// A release from GitHub's `GET /repos/{owner}/{repo}/releases/latest`, as
/// the updater needs it.
public struct GitHubRelease: Hashable, Sendable {
    public let tag: String
    public let version: SemanticVersion
    public let page: URL?
    public let notes: String
    public let prerelease: Bool

    /// Nil unless the answer has a `tag_name` that's a version ("v1.2.3").
    /// The page link must be https; missing notes are empty.
    public static func parse(_ data: Data) -> GitHubRelease? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, let version = SemanticVersion(tag) else { return nil }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return GitHubRelease(tag: tag, version: version, page: page, notes: obj["body"] as? String ?? "",
                             prerelease: obj["prerelease"] as? Bool ?? false)
    }
}
