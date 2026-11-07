import CoworkKit
import Foundation
import GitCoworkCLIKit
import GitCoworkCore

// `git cowork`: the team's tasks and review requests from the terminal.
// Same data as the app (refs/cowork/main), written the same way.

let usage = """
usage: git cowork <command> [options]

Tasks
  list [--mine] [--assignee WHO] [--status S] [--label L] [--all]
                                 open tasks (--all includes done)
  show <ID>                      a task or review, with comments
  new <title> [--status S] [--assign WHO] [--label L]... [--body TEXT]
                                 prints the new task's id
  edit <ID> [--title T] [--body TEXT] [--status S] [--assign WHO]
            [--label L | --label -L]... [--branch NAME|none]
  move <ID> <status>             backlog, todo, doing, review, done
  assign <ID> <WHO>              WHO: me, none, an email, or a teammate's handle
  done <ID>
  comment <ID> <text>            on a task or a review
  start <ID> [--worktree] [--worktree-path PATH]
                                 check out (or create) the task's branch here,
                                 or in its own worktree; links it, moves the
                                 task to doing and assigns it to you

Reviews
  reviews [--waiting | --mine | --all]
                                 open reviews (--waiting: asked of you)
  review <branch> --to WHO[,WHO] [--base B] [--title T] [--body TEXT] [--task ID]
  approve <R-ID> [comment]
  changes <R-ID> <what should change>

Other
  inbox                          assigned to you, review requests, @mentions, replies
  sync                           fetch, merge and push the shared tasks now

Options
  --json         machine-readable output (for agents and scripts)
  --sync         fetch teammates' changes before reading
  --no-sync      don't push after a change (it goes out with the next sync)
  --remote NAME  remote to sync with (default: git config cowork.remote, else a
                 remote that already has tasks, else origin; same as the app)
  -C PATH        run in another repository

Titles and comments don't need quotes: git cowork new Fix login bug.
Tasks live in the repository on refs/cowork/main and sync through your
normal remote. Your identity is git config user.email.
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("git-cowork: \(message)\n".utf8))
    exit(code)
}

let argv = Array(CommandLine.arguments.dropFirst())
let args: Args
do { args = try Args(argv) } catch CLIError.usage(let m) { fail("\(m)\n\n\(usage)", code: 2) }

guard let typed = args.positional.first, !args.flag("help"), typed != "help" else {
    print(usage)
    exit(args.positional.isEmpty && !args.flag("help") ? 2 : 0)
}
do { try CommandSpec.check(args) } catch CLIError.usage(let m) { fail("\(m) (see git cowork help)", code: 2) }
let command = CommandSpec.canonical(typed) ?? typed

let git = ProcessGit()
let start = URL(fileURLWithPath: args.value("C") ?? FileManager.default.currentDirectoryPath)
let top = await git.git(["rev-parse", "--show-toplevel"], in: start)
guard top.ok, !top.line.isEmpty else { fail("not in a git repository", code: 1) }
let root = URL(fileURLWithPath: top.line)

let me = await CoworkRepo.identity(root: root, git: git)
if me.email.isEmpty && ["new", "edit", "move", "assign", "done", "comment", "start", "review", "approve", "changes"].contains(command) {
    fail("set your email first: git config user.email you@example.com", code: 1)
}

// Same remote as the app: --remote, else CoworkRemote's choice.
let remote: String?
if let r = args.value("remote") { remote = r } else { remote = await CoworkRemote.choose(root: root, git: git).remote }

let commands = Commands(args: args, repo: CoworkRepo(root: root, git: git, me: me), remote: remote)
do {
    switch command {
    case "list": try await commands.list()
    case "show": try await commands.show()
    case "new": try await commands.new()
    case "edit": try await commands.edit()
    case "move": try await commands.edit(status: Commands.status(args.arg(2, "status")))
    case "assign": try await commands.assign(args.arg(2, "who (me, none or an email)"))
    case "done": try await commands.edit(status: .done)
    case "comment": try await commands.comment()
    case "start": try await commands.start()
    case "reviews": try await commands.reviews()
    case "review": try await commands.requestReview()
    case "approve": try await commands.verdict(.approved)
    case "changes": try await commands.verdict(.changesRequested)
    case "inbox": try await commands.inbox()
    case "sync": try await commands.sync()
    default: fail("unknown command \(typed)\n\n\(usage)", code: 2)
    }
} catch CLIError.usage(let m) {
    fail("\(m) (see git cowork help)", code: 2)
} catch CLIError.failed(let m) {
    fail(m, code: 1)
} catch {
    fail(error.localizedDescription, code: 1)
}
