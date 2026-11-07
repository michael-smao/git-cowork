import GitCoworkCore
import SwiftUI

// Small building blocks shared by all screens.

/// Pill showing a branch or tag name.
struct RefBadge: View {
    let ref: Ref
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: ref.symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(ref.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(Theme.Font.small.weight(ref.isHead ? .semibold : .regular))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(Theme.Tint.chip), in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
        .help(ref.name)
    }
}

extension Ref {
    var symbol: String {
        switch kind {
        case .localBranch: isHead ? "checkmark" : "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        }
    }
}

/// A count. Styles:
/// - `.plain`: small grey number (section headers, folders).
/// - `.accent`: white on an accent capsule (reviews waiting for me).
/// - `.warning`: tinted capsule (uncommitted changes of a worktree).
/// - `.toolbar`: tiny filled badge on a toolbar icon (commits to push, unread).
struct CountBadge: View {
    enum Style { case plain, accent, warning, toolbar }
    let count: Int
    var style: Style = .plain
    /// Fixed column width, so counts line up across rows (sidebar headers).
    var column: CGFloat?
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        switch style {
        case .plain:
            number
                .foregroundStyle(.secondary)
                .frame(minWidth: column, minHeight: column == nil ? nil : 16, alignment: .trailing)
        case .accent:
            number
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Space.s)
                .frame(minWidth: column, minHeight: 16)
                .background(Capsule().fill(Color.accentColor))
        case .warning:
            number
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 1)
                .background(Theme.Status.warning.opacity(Theme.Tint.chip), in: Capsule())
                .foregroundStyle(Theme.Status.warning)
        case .toolbar:
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 13, minHeight: 13)
                .background(Capsule().fill(Color.accentColor))
                .opacity(enabled ? 1 : 0.4)
        }
    }

    private var number: some View {
        Text(verbatim: "\(count)").font(Theme.Font.caption.monospacedDigit())
    }
}

/// "↑2 ↓1" next to a branch or worktree. Shows nothing when in sync.
struct AheadBehind: View {
    let ahead: Int
    let behind: Int

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if ahead > 0 { Text(verbatim: "↑\(ahead)") }
            if behind > 0 { Text(verbatim: "↓\(behind)") }
        }
        .font(Theme.Font.small.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// Initials in a colored circle. No network lookups.
struct Avatar: View {
    let name: String
    let email: String
    var size = Theme.AvatarSize.l

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(nsColor: Theme.personColor(email)), in: Circle())
    }

    var initials: String { name.initials }
}


/// Top bar of a panel: `panelHeaderHeight` tall, content inset by
/// `panelPadding`, one hairline underneath. Every panel uses it, so the
/// bars' bottom borders form one line across the window.
struct PanelBar<Content: View>: View {
    var spacing = Theme.Space.m
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: spacing) { content }
                .padding(.horizontal, Theme.Metrics.panelPadding)
                .frame(height: Theme.Metrics.panelHeaderHeight)
            Divider()
        }
    }
}

/// Caption above a group: "Description", "Comments 3", "Unstaged files 3".
/// With `collapsed` it gets a chevron and clicking the title toggles it.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    var collapsed: Binding<Bool>?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let collapsed {
                Button {
                    collapsed.wrappedValue.toggle()
                } label: {
                    HStack(spacing: Theme.Space.s) {
                        DisclosureChevron(expanded: !collapsed.wrappedValue).frame(width: Theme.Metrics.chevronWidth)
                        label
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
            } else {
                label.layoutPriority(1)
            }
            Spacer(minLength: Theme.Space.s)
            trailing
        }
        .frame(minHeight: Theme.Metrics.chipHeight)
    }

    private var label: some View {
        HStack(spacing: Theme.Space.s) {
            Text(ui: title)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let count { CountBadge(count: count) }
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// Disclosure chevron of collapsible sections, folders and tree rows.
struct DisclosureChevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(Theme.Glyph.chevron)
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
    }
}

/// Lays out children left to right, wrapping onto new lines. A child wider
/// than the row is narrowed to the row width (its text truncates).
struct FlowRow: Layout {
    var spacing: CGFloat = Theme.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = size(of: v, maxWidth: width)
            if x > 0 && x + s.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            maxX = max(maxX, x + s.width)
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for v in subviews {
            let s = size(of: v, maxWidth: bounds.width)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }

    private func size(of v: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = v.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth, maxWidth.isFinite else { return ideal }
        let s = v.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        return CGSize(width: min(s.width, maxWidth), height: s.height)
    }
}

/// Centered placeholder for empty panels, with an optional button below.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    var message: String?
    /// Narrower column for a long message.
    var messageWidth: CGFloat?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(ui: title).font(Theme.Font.body.weight(.medium))
            if let message {
                Text(ui: message)
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: messageWidth)
            }
            if Actions.self != EmptyView.self {
                actions.padding(.top, Theme.Space.s)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String? = nil) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// Standard sheet layout: title, content, an optional error, then the
/// button row: busy spinner, extra buttons, Cancel, primary button.
struct SheetScaffold<Content: View, Extra: View>: View {
    let title: String
    /// Nil leaves out the primary button.
    let confirmTitle: String?
    var confirmDisabled = false
    var error: String?
    /// Monospaced error, for command output.
    var monoError = false
    /// Spinner label at the start of the button row ("Cloning…"); also
    /// disables the primary button.
    var busy: LocalizedStringKey?
    var showsCancel = true
    /// False for sheets that close themselves once the work succeeds.
    var dismissOnConfirm = true
    var width: CGFloat = 440
    var onCancel: () -> Void = {}
    let onConfirm: () -> Void
    @ViewBuilder var content: Content
    /// Buttons left of Cancel.
    @ViewBuilder var extraButtons: Extra
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(ui: title).font(Theme.Font.title)
            content
            if let error {
                ErrorText(error, mono: monoError).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let busy { ProgressLabel(busy) }
                Spacer()
                extraButtons
                if showsCancel {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                if let confirmTitle {
                    Button(LocalizedStringKey(confirmTitle)) {
                        onConfirm()
                        if dismissOnConfirm { dismiss() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmDisabled || busy != nil)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: width)
    }
}

extension SheetScaffold where Extra == EmptyView {
    init(title: String, confirmTitle: String?, confirmDisabled: Bool = false, error: String? = nil,
         monoError: Bool = false, busy: LocalizedStringKey? = nil, dismissOnConfirm: Bool = true,
         width: CGFloat = 440, onCancel: @escaping () -> Void = {},
         onConfirm: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title: title, confirmTitle: confirmTitle, confirmDisabled: confirmDisabled, error: error,
                  monoError: monoError, busy: busy, dismissOnConfirm: dismissOnConfirm, width: width,
                  onCancel: onCancel, onConfirm: onConfirm, content: content, extraButtons: { EmptyView() })
    }
}

/// Red message for a failed action or invalid input. Selectable, so it can be copied.
struct ErrorText: View {
    let text: String
    var mono = false

    init(_ text: String, mono: Bool = false) {
        self.text = text
        self.mono = mono
    }

    var body: some View {
        Text(verbatim: text)
            .font(mono ? Theme.Font.monoSmall : Theme.Font.small)
            .foregroundStyle(Theme.Status.error)
            .textSelection(.enabled)
    }
}

/// Small spinner with a quiet label: "Cloning…", "Waiting for approval…".
/// Without a label it is just the spinner.
struct ProgressLabel: View {
    var title: LocalizedStringKey?

    init(_ title: LocalizedStringKey? = nil) { self.title = title }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ProgressView().controlSize(.small)
            if let title {
                Text(title).font(Theme.Font.small).foregroundStyle(.secondary)
            }
        }
    }
}

/// The ▾ of pop-up menus.
struct DropdownChevron: View {
    var body: some View {
        Image(systemName: "chevron.down").font(Theme.Glyph.dropdown)
    }
}

/// Menu label: content followed by a ▾. `quiet` greys the chevron, for
/// labels whose content carries its own color (chips, avatars).
struct DropdownLabel<Content: View>: View {
    var spacing = Theme.Space.s
    var quiet = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) {
            content
            if quiet {
                DropdownChevron().foregroundStyle(.secondary)
            } else {
                DropdownChevron()
            }
        }
    }
}
