import Testing
@testable import GitCoworkCore

@Suite struct GitFailureTests {
    @Test func push() {
        #expect(GitFailure.classify("""
        To github.com:o/r.git
         ! [rejected]        main -> main (fetch first)
        error: failed to push some refs to 'github.com:o/r.git'
        hint: Updates were rejected because the remote contains work that you do not
        """) == .pushRejected)
        #expect(GitFailure.classify(" ! [rejected] main -> main (non-fast-forward)\nerror: failed to push some refs") == .pushRejected)
        #expect(GitFailure.classify(" ! [rejected] main -> main (stale info)\nerror: failed to push some refs") == .staleLease)
        #expect(GitFailure.classify("remote: error: GH006: Protected branch update failed for refs/heads/main.") == .protectedBranch)
        #expect(GitFailure.classify("error: unable to delete 'x': remote ref does not exist") == .remoteRefMissing)
        #expect(GitFailure.classify("remote: Permission to o/r.git denied to anna.\nfatal: unable to access 'https://github.com/o/r.git/': The requested URL returned error: 403") == .noWriteAccess)
    }

    /// GitLab ends every server-side refusal with "pre-receive hook declined";
    /// only the remote: line says whether it's branch protection.
    @Test func serverRejected() {
        let rejected = " ! [remote rejected] development -> development (pre-receive hook declined)\nerror: failed to push some refs to 'gitlab.com:o/r.git'"
        #expect(GitFailure.classify("remote: GitLab: You are not allowed to push code to protected branches on this project.\n" + rejected)
                == .protectedBranch)
        // git pads remote lines with spaces when it writes to a pipe.
        #expect(GitFailure.classify("remote: GitLab: Commit must be signed with a GPG key        \nTo gitlab.com:o/r.git\n" + rejected)
                == .serverRejected(reason: "GitLab: Commit must be signed with a GPG key"))
        #expect(GitFailure.classify(rejected) == .serverRejected(reason: ""))
        #expect(GitFailure.classify("""
        remote: error: GH013: Repository rule violations found for refs/heads/main.
        remote: Review all repository rules at https://github.com/o/r/rules
        remote:
        remote: - Commits must have verified signatures.
        To github.com:o/r.git
         ! [remote rejected] main -> main (push declined due to repository rule violations)
        error: failed to push some refs to 'github.com:o/r.git'
        """) == .serverRejected(reason: """
        GH013: Repository rule violations found for refs/heads/main.
        Review all repository rules at https://github.com/o/r/rules
        - Commits must have verified signatures.
        """))
    }

    @Test func pull() {
        #expect(GitFailure.classify("There is no tracking information for the current branch.\nPlease specify which branch you want to merge with.") == .noUpstream)
        #expect(GitFailure.classify("Your configuration specifies to merge with the ref 'refs/heads/x'\nfrom the remote, but no such ref was fetched.") == .upstreamGone)
    }

    @Test func workingCopy() {
        let checkout = """
        error: Your local changes to the following files would be overwritten by checkout:
        \tSources/a.swift
        \tREADME.md
        Please commit your changes or stash them before you switch branches.
        Aborting
        """
        #expect(GitFailure.classify(checkout) == .localChangesOverwritten(files: ["Sources/a.swift", "README.md"]))
        #expect(GitFailure.classify("error: The following untracked working tree files would be overwritten by checkout:\n\tnew.txt\nAborting")
                == .untrackedOverwritten(files: ["new.txt"]))
        #expect(GitFailure.classify("error: cannot rebase: You have unstaged changes.\nerror: Please commit or stash them.") == .dirtyWorkingCopy)
        #expect(GitFailure.classify("CONFLICT (content): Merge conflict in a.txt\nAutomatic merge failed; fix conflicts and then commit the result.") == .conflicts)
        #expect(GitFailure.classify("error: could not apply 1234567... change\nhint: Resolve all conflicts manually") == .conflicts)
    }

    @Test func setup() {
        #expect(GitFailure.classify("Author identity unknown\n\n*** Please tell me who you are.") == .identityUnknown)
        #expect(GitFailure.classify("Host key verification failed.\nfatal: Could not read from remote repository.") == .hostKeyUnknown)
        #expect(GitFailure.classify("fatal: Authentication failed for 'https://github.com/o/r.git/'") == .signIn)
        #expect(GitFailure.classify("fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com") == .offline)
        #expect(GitFailure.classify("fatal: a branch named 'x' already exists") == .alreadyExists)
        #expect(GitFailure.classify("fatal: detected dubious ownership in repository at '/x'") == .notARepository)
        #expect(GitFailure.classify("something unexpected") == .other)
    }
}

@Suite struct WorktreePathUniqueTests {
    @Test func addsSuffix() {
        #expect(WorktreePath.unique("/a/b", exists: { _ in false }) == "/a/b")
        #expect(WorktreePath.unique("/a/b", exists: { $0 == "/a/b" }) == "/a/b-2")
        #expect(WorktreePath.unique("/a/b", exists: { ["/a/b", "/a/b-2"].contains($0) }) == "/a/b-3")
    }
}
