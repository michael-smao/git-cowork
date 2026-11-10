import GitCoworkCore
import SwiftUI

/// "Where should <branch> push to?" for a branch without an upstream, like
/// GitKraken: pick the remote and the branch name there (the same by default).
struct PushTargetSheet: View {
    let model: RepoModel
    let branch: String
    @State private var remote: String
    @State private var name: String
    @State private var running = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: RepoModel, branch: String) {
        self.model = model
        self.branch = branch
        _remote = State(initialValue: model.defaultRemote ?? model.remoteNames.first ?? "origin")
        _name = State(initialValue: branch)
    }

    var body: some View {
        SheetScaffold(title: String(localized: "Push \(branch)"), confirmTitle: "Push",
                      confirmDisabled: !RefName.isValid(name) || running, error: error,
                      busy: running ? "Pushing…" : nil, dismissOnConfirm: false) {
            push()
        } content: {
            Text("\(branch) isn't on a remote yet. Where should it push to and pull from?")
                .font(Theme.Font.small).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Remote", selection: $remote) {
                    ForEach(model.remoteNames, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Text(verbatim: "/").foregroundStyle(.secondary)
                TextField("Branch name", text: $name).textFieldStyle(.roundedBorder)
            }
            if model.remoteBranch(fullName: "\(remote)/\(name)") != nil {
                Text("\(remote)/\(name) already exists; the push adds your commits to it if it can.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
            }
        }
    }

    private func push() {
        running = true
        error = nil
        Task {
            let ok = await model.push(branch: branch, to: remote, as: name, quiet: true)
            running = false
            if ok { dismiss() } else { error = model.lastProblem.map { "\($0.title)\n\($0.message)" } }
        }
    }
}

/// Add a remote (name and URL). For a repository without one it then pushes
/// `thenPush`; for another remote (a fork, the original) it fetches it.
struct AddRemoteSheet: View {
    let model: RepoModel
    let thenPush: String?
    @State private var name: String
    @State private var url = ""
    @State private var running = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: RepoModel, thenPush: String?) {
        self.model = model
        self.thenPush = thenPush
        // The usual names, in the usual order: origin, then upstream.
        let free = ["origin", "upstream"].first { !model.remoteNames.contains($0) }
        _name = State(initialValue: free ?? "")
    }

    private var isFirst: Bool { model.remotes.isEmpty }
    private var taken: Bool { model.remoteNames.contains(name) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        SheetScaffold(title: "Add Remote", confirmTitle: thenPush == nil ? "Add" : "Add and Push",
                      confirmDisabled: !RefName.isValid(name) || taken || !RemoteURL.isUsable(trimmedURL) || running,
                      error: error, busy: running ? "Working…" : nil, dismissOnConfirm: false) {
            add()
        } content: {
            Text(isFirst ? "This repository has no remote yet. Create an empty repository on GitHub, GitLab or your server, then paste its URL."
                         : "Another place to fetch from and push to, for example your fork or the repository you forked from. Its branches show under Remote once it's fetched.")
                .font(Theme.Font.small).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            if taken { NameTaken(text: String(localized: "A remote named \(name) already exists.")) }
            TextField("git@github.com:org/repo.git or https://…", text: $url).textFieldStyle(.roundedBorder)
        }
    }

    private func add() {
        running = true
        error = nil
        let url = trimmedURL, name = name
        Task {
            var ok = await model.addRemote(name: name, url: url, quiet: true)
            if ok, let branch = thenPush { ok = await model.push(branch: branch, to: name, as: branch, quiet: true) }
            running = false
            guard ok else {
                error = model.lastProblemText
                return
            }
            dismiss()
            // Nothing was pushed, so nothing of the remote is here yet: get its
            // branches. A wrong URL shows now, with the remote there to edit.
            if thenPush == nil { await model.fetch(remote: name) }
        }
    }
}

/// Rename a remote or change its URL.
struct EditRemoteSheet: View {
    let model: RepoModel
    let old: String
    private let oldURL: String
    @State private var name: String
    @State private var url: String
    @State private var running = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: RepoModel, old: String) {
        self.model = model
        self.old = old
        oldURL = model.remotes.first { $0.name == old }?.url ?? ""
        _name = State(initialValue: old)
        _url = State(initialValue: oldURL)
    }

    private var taken: Bool { name != old && model.remoteNames.contains(name) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespaces) }
    private var unchanged: Bool { name == old && trimmedURL == oldURL }

    var body: some View {
        SheetScaffold(title: String(localized: "Edit Remote \(old)"), confirmTitle: "Save",
                      confirmDisabled: !RefName.isValid(name) || taken || !RemoteURL.isUsable(trimmedURL) || unchanged || running,
                      error: error, busy: running ? "Working…" : nil, dismissOnConfirm: false) {
            save()
        } content: {
            // Both fields come filled in, so they get labels (like Add Worktree).
            Form {
                TextField("Name", text: $name)
                TextField("URL", text: $url, prompt: Text("git@github.com:org/repo.git or https://…"))
            }
            .formStyle(.columns)
            if taken { NameTaken(text: String(localized: "A remote named \(name) already exists.")) }
            if name != old, RefName.isValid(name), !taken {
                Text("Its branches are then called \(name)/…, and local branches keep following them.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        running = true
        error = nil
        let url = trimmedURL, name = name
        Task {
            let ok = await model.editRemote(old, name: name, url: url, quiet: true)
            running = false
            if ok { dismiss() } else { error = model.lastProblemText }
        }
    }
}

/// What the sheets accept as a remote's URL.
enum RemoteURL {
    /// Not empty, on one line, and not something git would read as an option.
    /// Spaces are fine: a remote can be a folder on this Mac.
    static func isUsable(_ url: String) -> Bool {
        !url.isEmpty && !url.hasPrefix("-") && !url.contains(where: \.isNewline)
    }
}

/// Name and email for commits, asked once instead of git's "Please tell me who you are".
struct IdentitySheet: View {
    let model: RepoModel
    @State private var name = NSFullUserName()
    @State private var email = ""
    @State private var global = true
    @State private var running = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && email.contains("@")
    }

    var body: some View {
        SheetScaffold(title: "Who Are You?", confirmTitle: "Save and Commit", confirmDisabled: !valid || running,
                      error: error, busy: running ? "Saving…" : nil, dismissOnConfirm: false, onCancel: { model.afterIdentity = nil }) {
            save()
        } content: {
            Text("Git signs every commit with a name and email. Use the email of your GitHub or GitLab account so commits link to you there.")
                .font(Theme.Font.small).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Email", text: $email).textFieldStyle(.roundedBorder)
            Toggle("Use for all repositories", isOn: $global).toggleStyle(.checkbox)
        }
    }

    private func save() {
        running = true
        error = nil
        Task {
            // Close first: the commit that was waiting runs right after saving.
            let saved = await model.saveIdentity(name: name.trimmingCharacters(in: .whitespaces),
                                                 email: email.trimmingCharacters(in: .whitespaces), global: global)
            running = false
            if saved { dismiss() } else { error = model.lastProblem.map { "\($0.title)\n\($0.message)" } }
        }
    }
}
