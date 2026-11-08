import GitCoworkCore
import SwiftUI

// Rows of the sidebar list. Each is a single line of Theme.Metrics.rowHeight.

/// Indentation, disclosure chevron slot and icon shared by every row.
struct SidebarRowLayout<Leading: View, Content: View>: View {
    var depth = 0
    var height = Theme.Metrics.rowHeight
    @ViewBuilder var leading: Leading
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if depth > 0 { Color.clear.frame(width: CGFloat(depth) * SidebarStyle.indent) }
            ZStack { leading }.frame(width: SidebarStyle.chevronWidth, height: height)
            content
        }
        .font(Theme.Font.body)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension SidebarRowLayout where Leading == EmptyView {
    init(depth: Int = 0, height: CGFloat = Theme.Metrics.rowHeight, @ViewBuilder content: () -> Content) {
        self.init(depth: depth, height: height, leading: { EmptyView() }, content: content)
    }
}

struct SidebarIcon: View {
    let symbol: String
    var color: Color = .secondary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: SidebarStyle.iconSize))
            .foregroundStyle(color)
            .frame(width: Theme.Metrics.iconWidth)
    }
}

/// Badges at the end of a row. Laid out first and never truncated; names give way instead.
struct SidebarTrailing<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Theme.Space.s) { content }
            .fixedSize()
            .layoutPriority(2)
    }
}

/// Tinted rounded band behind the checked-out branch / current worktree.
struct CurrentBand: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.background {
            if active {
                RoundedRectangle(cornerRadius: SidebarStyle.bandRadius)
                    .fill(SidebarStyle.currentBand)
                    .padding(SidebarStyle.bandInset)
            }
        }
    }
}

// MARK: - Header

/// "› [icon] LOCAL ……… [+] 12". Clicking anywhere toggles the section.
struct SidebarSectionHeader<Trailing: View>: View {
    let section: SidebarSection
    let count: Int
    /// Nil when the header can't collapse (filtered results).
    let expanded: Bool?
    /// Accent count (reviews waiting for me).
    var highlight = false
    var showsDivider = true
    /// Replaces the section's own title ("Merge Requests" on GitLab).
    var title: String?
    var toggle: () -> Void = {}
    @ViewBuilder var trailing: Trailing

    var body: some View {
        SidebarRowLayout(height: Theme.Metrics.rowHeight) {
            if let expanded { DisclosureChevron(expanded: expanded) }
        } content: {
            SidebarIcon(symbol: section.symbol)
            Text(title ?? section.title)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Space.s)
            SidebarTrailing {
                trailing
                CountBadge(count: count, style: highlight ? .accent : .plain, column: SidebarStyle.countWidth)
            }
        }
        .overlay(alignment: .top) {
            if showsDivider { Divider().padding(.horizontal, SidebarStyle.bandInset.leading) }
        }
        .onTapGesture { toggle() }
    }
}

extension SidebarSectionHeader where Trailing == EmptyView {
    init(section: SidebarSection, count: Int, expanded: Bool?, highlight: Bool = false,
         showsDivider: Bool = true, title: String? = nil, toggle: @escaping () -> Void = {}) {
        self.init(section: section, count: count, expanded: expanded, highlight: highlight,
                  showsDivider: showsDivider, title: title, toggle: toggle) { EmptyView() }
    }
}

// MARK: - Tree rows

/// Branch folder ("claude", "feature") or remote ("origin"). Click toggles.
struct SidebarGroupRow: View {
    let name: String
    let symbol: String
    let expanded: Bool
    let depth: Int
    let toggle: () -> Void

    var body: some View {
        SidebarRowLayout(depth: depth) {
            DisclosureChevron(expanded: expanded)
        } content: {
            SidebarIcon(symbol: symbol)
            Text(name).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .onTapGesture { toggle() }
    }
}

/// Local or remote branch, or tag.
struct SidebarRefRow: View {
    let ref: Ref
    let label: String
    let depth: Int
    var ci: CIState?

    var body: some View {
        SidebarRowLayout(depth: depth) {
            SidebarIcon(symbol: symbol, color: ref.isHead ? .accentColor : .secondary)
            Text(label)
                .fontWeight(ref.isHead ? .semibold : .regular)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s)
            SidebarTrailing {
                if ref.upstreamGone {
                    Image(systemName: "cloud.slash")
                        .font(.system(size: SidebarStyle.iconSize))
                        .foregroundStyle(.tertiary)
                        .help("Upstream branch was deleted")
                }
                CIIcon(state: ci)
                if ref.ahead > 0 || ref.behind > 0 { AheadBehind(ahead: ref.ahead, behind: ref.behind) }
            }
        }
        .modifier(CurrentBand(active: ref.isHead))
        .help(ref.upstream.map { "\(ref.name) → \($0)" } ?? ref.name)
    }

    private var symbol: String {
        switch ref.kind {
        case .localBranch: ref.isHead ? "checkmark" : "arrow.triangle.branch"
        case .remoteBranch: "arrow.triangle.branch"
        case .tag: "tag"
        }
    }
}

/// Worktree: [branch] name  [folder] dir   3  ↑1. The current one gets a band and a dot.
/// The folder is shown only when both names fit; otherwise the branch gets the
/// whole width and the folder moves to the tooltip.
struct SidebarWorktreeRow: View {
    let model: RepoModel
    let wt: Worktree
    let isCurrent: Bool
    /// Repository name, used to shorten folder names like "repo-feature-x".
    let repoName: String

    var body: some View {
        let folder = wt.sidebarFolderLabel(repoName: repoName)
        SidebarRowLayout {
            if isCurrent {
                Circle().fill(Color.accentColor).frame(width: SidebarStyle.currentDot, height: SidebarStyle.currentDot)
            }
        } content: {
            SidebarIcon(symbol: wt.branch == nil ? "smallcircle.filled.circle" : "arrow.triangle.branch",
                        color: isCurrent ? .accentColor : .secondary)
            if let folder {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.m) {
                        branchText.fixedSize()
                        folderText(folder).fixedSize()
                    }
                    branchText.truncationMode(.middle)
                }
            } else {
                branchText.truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.s)
            SidebarTrailing {
                if wt.isPrunable {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.tertiary)
                        .help("Folder is missing; prune to clean up")
                }
                if wt.isLocked {
                    Image(systemName: "lock").foregroundStyle(.tertiary).help("Locked")
                }
                CIIcon(state: model.ciState(wt.head))
                // Own view, so `git status` results arriving per worktree only
                // redraw this badge, not the whole sidebar list.
                WorktreeInfoBadges(model: model, path: wt.path)
            }
        }
        .modifier(CurrentBand(active: isCurrent))
        .help(folder.map { "\(branchLabel)\n\($0) — \(wt.path)" } ?? "\(branchLabel)\n\(wt.path)")
    }

    private var branchText: some View {
        Text(branchLabel).fontWeight(isCurrent ? .semibold : .regular)
    }

    private func folderText(_ folder: String) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "folder").font(.system(size: SidebarStyle.iconSize - 1))
            Text(folder)
        }
        .font(Theme.Font.small)
        .foregroundStyle(.secondary)
    }

    private var branchLabel: String {
        if let b = wt.branch { return b }
        return wt.head.map { "detached " + String($0.prefix(7)) } ?? "detached"
    }
}

/// Change count and ahead/behind for one worktree, read straight from the model.
struct WorktreeInfoBadges: View {
    let model: RepoModel
    let path: String

    var body: some View {
        if let info = model.worktreeInfo[path] {
            if info.changes > 0 {
                CountBadge(count: info.changes, style: .warning).help("\(info.changes) uncommitted changes")
            }
            if info.ahead > 0 || info.behind > 0 { AheadBehind(ahead: info.ahead, behind: info.behind) }
        }
    }
}

struct SidebarStashRow: View {
    let stash: Stash

    var body: some View {
        SidebarRowLayout {
            SidebarIcon(symbol: "tray")
            Text(stash.message).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help("\(stash.selector): \(stash.message)")
    }
}

/// "All Tasks…", "Edit Team…": a quiet clickable row at the end of a section.
struct SidebarLinkRow: View {
    let link: SidebarLink
    let action: () -> Void

    var body: some View {
        SidebarRowLayout {
            SidebarIcon(symbol: link.symbol, color: Color(nsColor: .tertiaryLabelColor))
            Text(link.title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .onTapGesture(perform: action)
    }
}

/// Muted placeholder line inside an empty section.
struct SidebarNoteRow: View {
    let text: String

    var body: some View {
        SidebarRowLayout {
            Color.clear.frame(width: Theme.Metrics.iconWidth)
            Text(ui: text)
                .font(Theme.Font.small)
                .foregroundStyle(.tertiary)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help(Text(ui: text))
    }
}
