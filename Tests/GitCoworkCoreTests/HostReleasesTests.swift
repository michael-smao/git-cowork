import Foundation
import Testing
@testable import GitCoworkCore

@Suite struct HostReleasesTests {
    private func body(_ r: URLRequest?) throws -> [String: Any] {
        let data = try #require(r?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func githubRequest() throws {
        let r = HostAPI.createReleaseRequest(kind: .github, host: "github.com", path: "org/app", token: "t", tag: "v1.2.0",
                                             title: "1.2.0", notes: "- Fix", draft: true, prerelease: false)
        #expect(r?.url?.absoluteString == "https://api.github.com/repos/org/app/releases")
        #expect(r?.httpMethod == "POST")
        #expect(r?.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        let b = try body(r)
        #expect(b["tag_name"] as? String == "v1.2.0")
        #expect(b["name"] as? String == "1.2.0")
        #expect(b["body"] as? String == "- Fix")
        #expect(b["draft"] as? Bool == true)
        #expect(b["prerelease"] as? Bool == false)
    }

    @Test func gitlabRequestHasNoDraft() throws {
        let r = HostAPI.createReleaseRequest(kind: .gitlab, host: "gitlab.com", path: "group/sub/app", token: "t", tag: "v1",
                                             title: "v1", notes: "n", draft: true, prerelease: true)
        #expect(r?.url?.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fsub%2Fapp/releases")
        let b = try body(r)
        #expect(b["description"] as? String == "n")
        #expect(b["draft"] == nil && b["prerelease"] == nil && b["body"] == nil)
        #expect(!HostAPI.releaseHasDraftAndPrerelease(.gitlab))
        #expect(HostAPI.releaseHasDraftAndPrerelease(.github) && HostAPI.releaseHasDraftAndPrerelease(.gitea))
    }

    @Test func giteaRequest() throws {
        let r = HostAPI.createReleaseRequest(kind: .gitea, host: "codeberg.org", path: "org/app", token: "t", tag: "v1",
                                             title: "v1", notes: "", draft: false, prerelease: true)
        #expect(r?.url?.absoluteString == "https://codeberg.org/api/v1/repos/org/app/releases")
        #expect(r?.value(forHTTPHeaderField: "Authorization") == "token t")
        #expect(try body(r)["prerelease"] as? Bool == true)
    }

    @Test func repoPathCannotReachOtherEndpoints() {
        #expect(HostAPI.createReleaseRequest(kind: .github, host: "github.com", path: "../../user", token: "t", tag: "v1",
                                             title: "", notes: "", draft: false, prerelease: false) == nil)
    }

    @Test func parsesAnswers() {
        let gh = Data(#"{"html_url":"https://github.com/org/app/releases/tag/v1"}"#.utf8)
        #expect(HostAPI.parseCreatedRelease(status: 201, data: gh, kind: .github)
                == .created(URL(string: "https://github.com/org/app/releases/tag/v1")))
        let gl = Data(#"{"_links":{"self":"https://gitlab.com/g/app/-/releases/v1"}}"#.utf8)
        #expect(HostAPI.parseCreatedRelease(status: 201, data: gl, kind: .gitlab)
                == .created(URL(string: "https://gitlab.com/g/app/-/releases/v1")))
        // A page that isn't http(s) isn't opened.
        let odd = Data(#"{"html_url":"file:///etc/passwd"}"#.utf8)
        #expect(HostAPI.parseCreatedRelease(status: 201, data: odd, kind: .github) == .created(nil))
        #expect(HostAPI.parseCreatedRelease(status: 401, data: Data(), kind: .github) == .signedOut)
        let taken = Data(#"{"message":"Validation Failed","errors":[{"resource":"Release","code":"already_exists","field":"tag_name"}]}"#.utf8)
        #expect(HostAPI.parseCreatedRelease(status: 422, data: taken, kind: .github) == .alreadyExists)
        #expect(HostAPI.parseCreatedRelease(status: 409, data: Data(#"{"message":"Release already exists"}"#.utf8), kind: .gitlab) == .alreadyExists)
        // Other validation errors keep the host's message.
        let other = Data(#"{"message":"Validation Failed","errors":[{"code":"custom","message":"tag_name is not a valid tag"}]}"#.utf8)
        #expect(HostAPI.parseCreatedRelease(status: 422, data: other, kind: .github) == .failed("tag_name is not a valid tag"))
    }

    @Test func nextTag() {
        #expect(ReleaseDraft.nextTag(after: ["v0.6.2", "v0.6.10", "v0.6.3"]) == "v0.6.11")
        #expect(ReleaseDraft.nextTag(after: ["1.2", "nightly"]) == "1.2.1")
        // Pre-releases don't count.
        #expect(ReleaseDraft.nextTag(after: ["v1.0.0", "v2.0.0-beta.1"]) == "v1.0.1")
        #expect(ReleaseDraft.nextTag(after: ["nightly"]) == nil)
        #expect(ReleaseDraft.nextTag(after: []) == nil)
    }

    @Test func releasePageLinks() throws {
        let gh = try #require(RemoteLinks(remoteURL: "git@github.com:org/app.git"))
        #expect(gh.newReleaseURL(tag: "v1.0")?.absoluteString == "https://github.com/org/app/releases/new?tag=v1.0")
        let gl = try #require(RemoteLinks(remoteURL: "https://gitlab.com/group/app.git"))
        #expect(gl.newReleaseURL(tag: "v1.0")?.absoluteString == "https://gitlab.com/group/app/-/releases/new?tag_name=v1.0")
        // A tag can't break out of the query.
        #expect(gh.newReleaseURL(tag: "a&b=c")?.absoluteString == "https://github.com/org/app/releases/new?tag=a%26b%3Dc")
    }

    @Test func notes() {
        #expect(ReleaseDraft.notes(subjects: ["Fix tabs", "  ", " Add menu "]) == "- Fix tabs\n- Add menu")
        #expect(ReleaseDraft.notes(subjects: []) == "")
    }
}
