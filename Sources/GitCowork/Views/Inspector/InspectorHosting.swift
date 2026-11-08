import GitCoworkCore
import SwiftUI

/// Pull requests and CI for a commit. Empty when the host knows nothing.
struct HostLinks: View {
    let model: RepoModel
    let sha: String
    let branches: Set<String>

    /// Most unfinished or failed checks listed; the rest are on the host.
    private static let shownChecks = 5

    var body: some View {
        if let status = model.hostStatus {
            let pulls = branches.compactMap(status.pull(forBranch:))
            let unique = Array(Set(pulls)).sorted { $0.number < $1.number }
            let result = status.ci[sha]
            if !unique.isEmpty || result?.state != nil {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(unique) { pull in
                        CoworkLinkRow(label: status.links.kind == .gitlab ? "MR" : "PR", id: "#\(pull.number)", title: pull.title,
                                      help: String(localized: "Open on \(status.links.host)")) {
                            PullChip(pull: pull)
                        } action: { External.browse(pull.webURL) }
                    }
                    if let result, let state = result.state {
                        let open = result.checks.filter { $0.state != .success }
                        CoworkLinkRow(label: "CI", title: result.summary, help: String(localized: "Open on \(status.links.host)")) {
                            CIChip(state: state)
                        } action: { External.browse(open.first?.url ?? status.links.commitURL(sha)) }
                        ForEach(open.prefix(Self.shownChecks)) { HostCheckRow(check: $0) }
                    }
                }
            }
        }
    }
}

/// A failed or running check, under the CI row. Opens its log.
private struct HostCheckRow: View {
    let check: CICheck
    @State private var hovering = false

    var body: some View {
        Button { External.browse(check.url) } label: {
            HStack(spacing: Theme.Space.m) {
                Color.clear.frame(width: InspectorStyle.linkLabelWidth, height: 1)
                Image(systemName: check.state.symbol)
                    .font(.system(size: SidebarStyle.iconSize))
                    .foregroundStyle(check.state.color)
                Text(verbatim: check.name)
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .underline(hovering && check.url != nil)
                Spacer(minLength: 0)
            }
            .frame(height: Theme.Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(check.url == nil)
        .onHover { hovering = $0 }
        .help("\(check.name): \(check.state.title)")
    }
}
