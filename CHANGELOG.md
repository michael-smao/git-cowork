# Changelog

All notable changes to git-cowork. Versions follow
[Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.
How to update: see [INSTALL.md](INSTALL.md#quick-install) (or [from source](INSTALL.md#update-a-source-install)).

## [Unreleased]

## [0.5.3] - 2026-11-10

### Added
- Drag a repository tab sideways to move it. The other tabs step aside while
  you drag, the tab you are on stays selected, and the next launch reopens the
  tabs in the new order.

### Changed
- Dragging a tab no longer moves the window; drag the empty space next to the
  tabs for that. A tab in a window in the background reacts to the first click.
- At launch the tab that was in front opens first and right away; the other
  repositories join as tabs behind it, in their order, without windows
  popping up one after another. A background tab loads its repository when you
  first select it, so a launch with many tabs no longer loads all of them at
  once and the app stays responsive.
- A worktree's tab shows the repository name in full and cuts the worktree
  folder first.

### Fixed
- The app no longer stops running git commands after a while. With many
  commands at once (many repositories loading at launch), every worker thread
  ended up waiting for another one, so from then on actions never finished,
  deleting a remote branch waited forever and quitting hung. Each command now
  waits on a thread of its own.
- Commands that talk to a server can't hang forever: an HTTPS transfer that
  stalls for a minute fails, and fetch, pull and push stop after 10 minutes
  (ls-remote after 1). Clone has no limit.
- Push on a branch that follows a remote branch with another name (git
  refused with "The upstream branch of your current branch does not match")
  asks where to push: to that remote branch, or to a new one of the same name
  that the branch follows from now on.
- The list that expands from a row's branch badges covers the row's "+N", so
  it no longer peeks out next to it.

## [0.5.2] - 2026-11-10

### Added
- The repositories open when git-cowork quits open again at the next launch,
  as tabs in the same order with the same one in front. It no longer depends
  on macOS's "Close windows when quitting an app" setting. Turn it off in
  Settings › Reopen repositories at launch. Folders passed on the command line
  open after them, in front.
- Click a stash in the sidebar to see what's in it: its message, when and on
  which branch it was made, and its files, including the new (untracked) ones
  it took along. Click a file for its diff. Pop, Apply and Delete are in the
  panel too.
- The search field finds commits by content, across every branch and the whole
  history, not only the commits that are loaded: `file:name` for commits that
  changed a file whose path contains the text, `change:text` for commits that
  added or removed that text (`git log -S`). Both ignore case, take quotes for
  values with spaces (`change:"old name"`), and combine with plain words.
- When a search finds nothing, the list says so, and what the search looked at.
- Ignore for new files in Changes: right-click a file to ignore it, every file
  of its type, or its folder. Right-click a folder or several files to ignore
  those. It adds lines to `.gitignore` (creating it if needed), which then
  shows under Changes like any other edit.
- Remotes can be managed in the sidebar: + on Remote adds another one (a fork,
  the repository you forked from) and fetches it. Right-click a remote to
  fetch just that one, rename it, change its URL, copy the URL, open it on its
  host, or remove it. Removing asks first and says how many local branches
  follow it.

## [0.5.1] - 2026-11-09

### Added
- Discarding changes can be undone: Edit > Undo (⌘Z) brings them back,
  including new and deleted files, while staged changes stay untouched.
  A snapshot is saved before discarding; nothing is added to the stash list.
  Once those files are edited again, Undo refuses instead of overwriting the
  new edits.
- A short "Committed · Undo" hint after anything Edit > Undo can take back
  (commit, amend, reset, checkout, branch delete, discard).
- Reverting or cherry-picking a merge commit asks once and uses the side it
  was merged into (`-m 1`), instead of git's "is a merge but no -m option".

### Changed
- The search field in the toolbar searches what the window shows: commits in
  History, tasks on the Board, reviews in Reviews (by title, branch or ID).
  The Board's second search field is gone.
- The commit message in the commit panel is plain text instead of a box that
  looked like a field. The empty task panel shows the New Task shortcut as a
  keycap.

### Fixed
- A task without a linked branch cut off the left and right edges of its
  panel: its three branch buttons now wrap.
- Short names no longer get cut in the review header and the commit panel's
  "uncommitted files" strip.

## [0.5.0] - 2026-11-09

### Added
- Hovering a commit's branch and tag badges in the graph, when names are cut
  or some are behind "+N", shows all of them at full length in a list over the
  rows below. Click it to select the commit; right-click for the commit's menu.
- Remove a worktree from the graph: a branch checked out in another worktree,
  and another worktree's "// WIP" row, offer Open Worktree, Open Worktree in
  New Tab and Remove Worktree… in their right-click menu.
- Remove Worktree… in the sidebar also works for the worktree the tab shows:
  the tab then switches to the main worktree (or closes, when the main
  worktree is already open in another tab). The main worktree is never removed.
- Removing a worktree runs in the background: its row shows "Removing…" right
  away in every tab of the repository, and the rest of the app stays usable
  while git deletes the folder.
- A Fetch button in the toolbar, next to Pull: fetches all remotes
  (`git fetch --all --prune`) without merging anything.
- The first commit without a git name and email asks for them once (for all
  repositories or this one) and then commits.
- A repository without commits shows Create Initial Commit (adds a README.md
  if there is none).
- Stage All and Commit when nothing is staged yet.
- A banner when HEAD isn't on a branch, with Create Branch Here….
- Cloning into a folder that already holds the repository offers to open it;
  another folder of that name gets a `-2` suffix. Start Task in New Worktree
  does the same for its folder.

### Changed
- Repository tabs sit in their own row at the top of the window, next to the
  traffic lights, like GitKraken's, and are always shown, even with one
  repository open. Each tab shows the repository (and the folder of a linked
  worktree); click to switch, × or middle-click to close, + for a new tab.
  Before, the tabs could be missing altogether.
- The repository menu in the toolbar lists only repositories (this one and
  recent ones), like GitKraken. Worktrees get their own picker between
  repository and branch, shown when a repository has more than one: switch,
  open one in a new tab, or add one.
- Checking out a branch that another worktree has checked out (double-click
  or Checkout in the graph, a task's or review's Checkout, Start Task) opens
  that worktree instead of showing an alert: its tab comes to the front, or
  this window switches to it. Changes in this worktree stay where they are.
- The history scrolls to the checked-out branch when it opens and after a
  checkout, instead of always starting at the newest commit. With no changes
  to commit, the commit panel opens on that branch's commit too.
- Pull no longer stops with git's "divergent branches" error. It
  fast-forwards when only the remote moved, and when both sides have new
  commits it asks: Merge or Rebase. Uncommitted changes are put aside and
  back. A pull.rebase or pull.ff you set in git config is still followed,
  and Pull ▾ keeps its explicit variants.
- Double-clicking a remote branch checks out its local branch and brings it
  up to date the same way (a new tracking branch if there is none).
- The checked-out commit stands out in the history: its row has a stronger
  band in its lane color that reaches under the badges, and its branch badge
  is bold with a light ring.
- Failed git actions are explained in plain words with buttons for the next
  step, instead of git's raw output in an alert. git's own output is still
  there under Details, shown like a terminal (prompt, errors in red, hints
  dimmed), with Copy and the command log. Among them:
  - Push rejected because the remote moved: Pull, Then Push, or Force Push…,
    which always asks first and says what it overwrites.
  - Uncommitted changes in the way of a switch: Stash & Switch, or Bring
    Changes Along (to the branch's own remote branch, that's the default).
  - Pull or merge with no upstream, a deleted upstream, a protected branch,
    a stale lease, no write access, a new SSH host key, signed out, offline.
- Conflicts from a merge, rebase, cherry-pick, revert or stash open Changes
  instead of an alert; a stash applied with conflicts is kept and Changes
  offers to delete it once everything is resolved.
- Merge, rebase and all Pull variants put uncommitted changes aside and back
  (`--autostash`) instead of refusing.
- Deleting a local branch always asks, says how many commits exist only on
  it, and offers to delete its remote branch too. Deleting a remote branch
  that is already gone cleans up the leftover entry instead of failing.
- Pushing a branch without an upstream asks where to (remote and name, like
  GitKraken); a repository without a remote asks for one.
- A second git action waits for the running one instead of being refused.
- Sheets (new branch, tag, rename, stash, task, review request, create pull
  request) stay open with the error inline when something fails, and say
  when a branch or tag name is taken.

### Fixed
- A short tag or branch name like `v1` in a narrow Branch / Tag column no
  longer folds into "+1" when it fits.
- After removing a worktree, its "// WIP" row could stay in the graph.
- Settings scroll when they are taller than the window, and the window can be
  made taller. Before, the lower sections could not be reached on smaller screens.
- In a graph with more lanes than fit, a branch's line ran beside its commits:
  the nodes were moved to the column's edge, their lines weren't. Lines now
  move with them.
- Check for Updates could freeze the app: its message could open off screen
  while still blocking every window, so nothing could be clicked and the app
  could not even be quit. Its messages now open as a sheet on the front window.
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
