# Changelog

All notable changes to git-cowork. Versions follow
[Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.
How to update: see [INSTALL.md](INSTALL.md#quick-install) (or [from source](INSTALL.md#update-a-source-install)).

## [Unreleased]

### Fixed
- `GitCowork /path/to/repo` from a terminal could open the welcome screen
  instead of the folder: the first window often appeared before the command
  line was read, and nothing told it there was a folder to open.

## [0.4.0] - 2026-11-09

### Added
- Push any local branch from its right-click menu in the sidebar or the graph
  without checking it out, also when another worktree has it open.
- Settings › Language: follow macOS, or always English or German.
- Several accounts on one server, like personal and work on github.com. A
  repository uses the account you pick in its status bar (saved as
  `git config cowork.<host>.account`), else the one named in its URL, else the
  one added first. Cloning from an account's list keeps using that account.
- Pull/merge requests and CI, with an account for the host (GitHub, GitLab,
  Gitea, Forgejo): open requests in the sidebar, `#12` on their branches in
  the graph, CI passed/failed/running on branches and commits, the checks
  that failed in the commit panel with links to their logs, and Create Pull
  Request from the app. All worktree tabs of a repository share one lookup,
  and nothing is asked while the app is in the background.

### Changed
- Tokens in the Keychain are stored per account instead of per server. Existing
  ones move over by themselves.

### Fixed
- Two quick edits on the board could leave an older version of a task on screen
  until the next change. What was saved was always right.

## [0.3.0] - 2026-11-08

### Added
- Settings › Appearance: follow macOS, or always light or dark.
- Homebrew: `brew install --cask michael-smao/tap/git-cowork`, updates with
  `brew upgrade`. For Homebrew installs the app shows that command instead of
  updating itself.

### Changed
- Release notes, README and INSTALL say clearly not to download the zip in a
  browser, and how to replace a copy macOS blocked.
- The app and `git cowork` always sync tasks with the same remote:
  `git config cowork.remote` in the repository (the app saves its pick there).
  The app-wide "Sync remote" setting is gone.
- `git cowork new Fix login bug` works without quotes; unknown options and
  extra words are errors instead of being ignored; `--to anna` finds a
  teammate by handle; `approve`/`changes` honor `--json`.
- Start Task in the app and `git cowork start` pick the same branch and run
  the same git command (a pushed branch is tracked, a new one tracks nothing).

### Fixed
- install.sh keeps the old app if anything fails or is interrupted while
  replacing it, and says what to do when the app folder isn't writable.
- The in-app updater passes install.sh only the environment it needs, and
  gives up after 10 minutes.
- Branch names in shared tasks and reviews are checked before git sees them.
- Saving a renewed token no longer risks losing the old one.

## [0.2.0] - 2026-11-07

Coming from 0.1.0? Update once by hand with the one-line install (or
`make update`); 0.1.0 doesn't have the in-app updater yet.

### Added
- `git cowork` command-line tool for people and agents: list, create, edit,
  start (optionally in a new worktree) and comment on tasks; request, list and
  approve reviews; inbox; `--json` output. Installed with the app (one-line
  install or `make install`).
- One-line install without Xcode: `curl -fsSL …/install.sh | bash` downloads
  the newest release, checks its checksum and installs the app and
  `git cowork`. Releases now include the app as a zip.
- Updates from inside the app: a daily check (Settings › Updates) shows
  "Update to x.y.z" in the status bar; click it, then Update Now and
  Restart.
  Also git-cowork › Check for Updates….

## [0.1.0] - 2026-11-07

First public release.

### Git client
- Tabs for repositories and worktrees; repository and branch pickers.
- Commit graph with lane colors, author initials, branch badges and a
  `// WIP` row for every worktree with uncommitted changes.
- Sidebar with local and remote branches, worktrees (live uncommitted and
  ahead/behind counts), stashes and tags.
- Changes panel with staging per file or hunk, discard, commit and amend.
- Diff in hunk or split view with intra-line highlights.
- Pull, push, fetch, branch, stash, merge and rebase with conflict handling.
- Background fetch of every open repository every 5 minutes while the app is
  in front (Settings › Git › Fetch automatically). It never asks for
  credentials and pauses after a failed sign-in.
- Links to create pull/merge requests on GitHub, GitLab, Gitea and Forgejo.
- Settings > Accounts: sign in to GitHub or GitLab in the browser, or add an
  access token (also for Gitea and Forgejo), and HTTPS push and pull work
  without setting up git. Tokens are kept in the Keychain and used only by
  git-cowork; git in the terminal and SSH remotes are unchanged.
- Clone from your repos: with an account signed in, the Clone sheet lists
  your repositories and your organizations' or groups' (newest activity
  first), with a filter. Pick one to fill in its HTTPS URL, or double-click
  to clone it right away.
- Settings > Accounts > Create SSH Key: makes an ed25519 key in
  `~/.ssh/git-cowork_<host>`, keeps its random passphrase in the Keychain and
  adds it to your GitHub or GitLab account. git-cowork then uses it for SSH
  remotes on that host; `~/.ssh/config` isn't changed (SSH Host Entry shows a
  block to copy if the terminal should use the key too). Signing in now also
  asks for GitHub's `write:public_key` and GitLab's `api` scope; older
  sign-ins are asked to sign in again before adding a key.
- Command log (⌘J) showing every git command the app runs.
- Undo (⌘Z) for the last commit, amend, reset, checkout or branch delete,
  run as plain git commands; not offered once you've pushed.
- The app's own git calls ignore a repository's `core.fsmonitor` setting,
  so opening a repo can't start a program named in its config.
- English and German. The app follows your Mac's language; pick one for
  git-cowork alone in System Settings › General › Language & Region › Applications.
- If a macOS update removed Apple's developer tools (and with them git),
  the app says so at launch and offers to install them.

### Cowork
- Shared task board (Backlog, To Do, In Progress, In Review, Done) with
  assignees, labels, linked branches and comments.
- Review requests with reviewers, verdicts and comments.
- Inbox and macOS notifications for assignments, reviews and @mentions.
- Everything stored on `refs/cowork/main` and synced with plain git.
