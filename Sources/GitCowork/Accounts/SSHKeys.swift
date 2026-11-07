import CoworkKit
import Foundation
import GitCoworkCore
import SystemConfiguration

/// "Create SSH Key…": makes the key, keeps its passphrase in the Keychain,
/// and adds the public key to the account on the host. If anything fails,
/// what this run made is removed again, so a half-made key is never used.
enum SSHKeys {
    static var sshDir: String { NSHomeDirectory() + "/.ssh" }

    /// Where the next key for this account will go.
    static func plannedPath(for account: HostAccount) -> String? {
        SSHKey.newKeyPath(sshDir: sshDir, host: account.host, exists: FileManager.default.fileExists(atPath:))
    }

    /// Returns the private key's path once the host has the public key.
    static func create(for account: HostAccount) async throws -> String {
        guard let token = await Credentials.shared.tokens(for: account)?.access else {
            throw AccountError.noToken(account.host)
        }
        guard ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil else {
            throw AccountError(message: L("macOS's ssh-agent isn't available, so the key's passphrase can't be put in the Keychain."))
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: sshDir) {
            try? fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard let path = plannedPath(for: account) else {
            throw AccountError(message: L("Couldn't find a free file name for the key in ~/.ssh."))
        }

        // 1. Make the key. ssh-keygen won't replace a file that appeared meanwhile.
        let passphrase = SSHKey.newPassphrase()
        let comment = "\(account.username)@\(SSHKey.sshHost(account.host)) git-cowork"
        let keygen = await run("/usr/bin/ssh-keygen", SSHKey.keygenArgs(path: path, comment: comment),
                               input: SSHKey.passphraseInput(passphrase, times: 2))
        guard keygen.status == 0, let publicKey = try? String(contentsOfFile: path + ".pub", encoding: .utf8) else {
            if keygen.status == 0 { removeFiles(path) }   // never delete a file ssh-keygen refused to replace
            throw AccountError(message: String(localized: "ssh-keygen failed: \(keygen.stderr.isEmpty ? "exit \(keygen.status)" : keygen.stderr)"))
        }

        do {
            // 2. Passphrase into the Keychain, where ssh's UseKeychain finds it.
            //    ssh-add also loads the key into the agent; take it out again so
            //    ssh in the terminal doesn't start offering it to every server.
            let add = await run("/usr/bin/ssh-add", ["--apple-use-keychain", path],
                                input: SSHKey.passphraseInput(passphrase, times: 1))
            guard add.status == 0 else {
                throw AccountError(message: String(localized: "Couldn't put the key's passphrase in the Keychain: \(add.stderr)"))
            }
            _ = await run("/usr/bin/ssh-add", ["-d", path], input: Data())

            // 3. Add the public key to the account.
            try await upload(publicKey, for: account, token: token)
            return path
        } catch {
            _ = await run("/usr/bin/ssh-add", ["--apple-use-keychain", "-d", path], input: Data())
            removeFiles(path)
            throw error
        }
    }

    private static func upload(_ publicKey: String, for account: HostAccount, token: String) async throws {
        guard let scope = account.kind.sshKeyScope,
              let request = HostAPI.addSSHKeyRequest(kind: account.kind, host: account.host, token: token,
                                                     title: SSHKey.title(machine: machineName), publicKey: publicKey)
        else { throw AccountError(message: String(localized: "\(account.kind.title) servers can't take an SSH key from git-cowork.")) }
        let (data, response) = try await SignIn.send(request, host: account.host)
        let http = response as? HTTPURLResponse
        let result = HostAPI.parseAddSSHKey(status: http?.statusCode ?? 0, data: data, kind: account.kind,
                                            grantedScopes: http?.value(forHTTPHeaderField: "X-OAuth-Scopes"))
        switch result {
        case .added:
            return
        case .missingScope:
            let fix = account.method == .oauth
                ? L("Sign in again to allow it.")
                : String(localized: "Make a new token with the scopes \(account.kind.scopesHint) and add it with Add Token.")
            throw AccountError(message: String(localized: "Your sign-in on \(account.host) isn't allowed to add SSH keys (needs the \(scope) scope).") + " " + fix,
                               needsSignIn: true)
        case .signedOut:
            throw AccountError.tokenRejected(account.host)
        case .failed(let reason):
            throw AccountError(message: String(localized: "\(account.host) didn't add the key: \(reason)"))
        }
    }

    private static var machineName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    private static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".pub")
    }

    private static func run(_ tool: String, _ args: [String], input: Data) async -> (status: Int32, stderr: String) {
        let r = await Subprocess.run(tool, args, input: input)
        // Drop the passphrase prompts; they share a line with the real message.
        let stderr = r.errorText
            .replacingOccurrences(of: #"Enter (same )?passphrase[^:]*: "#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.exitCode, stderr)
    }
}
