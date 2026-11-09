import AppKit
import GitCoworkCore
import SwiftUI

/// A failed git action in plain words: what happened, buttons for the next
/// step, and git's own output underneath, styled like a terminal.
struct ProblemSheet: View {
    let problem: GitProblem
    let showLog: () -> Void
    @State private var showDetails = false
    @Environment(\.dismiss) private var dismiss

    init(problem: GitProblem, showLog: @escaping () -> Void) {
        self.problem = problem
        self.showLog = showLog
        #if DEBUG
        // GITCOWORK_DEBUG_DETAILS=1: open the details, for snapshots.
        _showDetails = State(initialValue: ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_DETAILS"] != nil)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                Image(systemName: problem.isInfo ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(problem.isInfo ? Theme.Status.info : Theme.Status.warning)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(verbatim: problem.title).font(Theme.Font.title)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: problem.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if problem.output != nil || problem.command != nil {
                DisclosureGroup(isExpanded: $showDetails) {
                    TerminalOutput(command: problem.command, output: problem.output ?? "")
                        .padding(.top, Theme.Space.s)
                } label: {
                    Text("Details from git").font(Theme.Font.small).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Command Log") {
                    dismiss()
                    showLog()
                }
                Spacer()
                Button(problem.actions.isEmpty ? "OK" : "Cancel") { dismiss() }
                    .keyboardShortcut(problem.actions.isEmpty ? .defaultAction : .cancelAction)
                ForEach(problem.actions) { action in
                    actionButton(action)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
    }

    @ViewBuilder
    private func actionButton(_ action: GitProblem.Action) -> some View {
        let button = Button(role: action.role == .destructive ? .destructive : nil) {
            dismiss()
            Task { await action.run() }
        } label: {
            Text(verbatim: action.title)
        }
        if action.role == .primary {
            button.keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }
}

/// git's output the way a terminal shows it: dark background, monospaced,
/// the command after a prompt, errors red, hints dimmed.
struct TerminalOutput: View {
    let command: String?
    let output: String

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            ScrollView([.vertical, .horizontal]) {
                Text(attributed)
                    .font(Theme.Font.monoSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
            }
            .frame(maxHeight: 220)
            .background(Theme.Terminal.background, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            Button("Copy") { External.copy(plain) }
                .buttonStyle(.link)
                .font(Theme.Font.small)
        }
    }

    private var plain: String {
        (command.map { "$ \($0)\n" } ?? "") + output
    }

    private var attributed: AttributedString {
        var all = AttributedString()
        if let command {
            var prompt = AttributedString("$ ")
            prompt.foregroundColor = Theme.Terminal.prompt
            var cmd = AttributedString(command + "\n")
            cmd.foregroundColor = Theme.Terminal.command
            all += prompt + cmd
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            var part = AttributedString(String(line) + "\n")
            let lower = line.lowercased()
            part.foregroundColor = lower.hasPrefix("error") || lower.hasPrefix("fatal") || lower.contains("[rejected]")
                ? Theme.Terminal.error
                : lower.hasPrefix("hint") ? Theme.Terminal.hint
                : lower.hasPrefix("warning") ? Theme.Terminal.warning
                : Theme.Terminal.text
            all += part
        }
        return all
    }
}
