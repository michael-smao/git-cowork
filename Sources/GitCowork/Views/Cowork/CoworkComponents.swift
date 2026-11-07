import GitCoworkCore
import SwiftUI

// Small pieces shared by the board, review list, task/review panels and sidebar.

/// Initials avatar for a person, colored the same way everywhere (graph nodes
/// use lane colors; people use this stable per-email color).
struct PersonAvatar: View {
    let person: TeamMember?
    var size = Theme.AvatarSize.l

    var body: some View {
        if let person {
            Avatar(name: person.displayName, email: person.email, size: size)
                .help("\(person.name) <\(person.email)>")
        } else {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
                .help("Unassigned")
        }
    }
}

/// Colored capsule with an icon: "In Progress", "Approved", label names.
/// `trailing` adds a control after the text (a remove button).
struct Chip<Trailing: View>: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary
    var filled = false
    /// Smaller right inset when `trailing` holds a button.
    var trailingPadding = Theme.Space.m
    @ViewBuilder var trailing: Trailing
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).lineLimit(1)
            trailing
        }
        .font(Theme.Font.small.weight(.medium))
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, trailingPadding)
        .frame(height: Theme.Metrics.chipHeight)
        .foregroundStyle(filled ? Color.white : color.readableTint(scheme))
        .background(filled ? color : color.opacity(Theme.Tint.chip), in: Capsule())
    }
}

extension Chip where Trailing == EmptyView {
    init(text: String, symbol: String? = nil, color: Color = .secondary, filled: Bool = false) {
        self.init(text: text, symbol: symbol, color: color, filled: filled) { EmptyView() }
    }
}

struct StatusChip: View {
    let status: TaskStatus
    var body: some View { Chip(text: status.label, symbol: status.symbol, color: status.color) }
}

struct VerdictChip: View {
    let verdict: ReviewVerdict
    var body: some View { Chip(text: verdict.title, symbol: verdict.symbol, color: verdict.color) }
}

/// "Open" / "Closed" capsule.
struct ReviewStateChip: View {
    let status: ReviewStatus
    var body: some View {
        switch status {
        case .open: Chip(text: "Open", symbol: "circle", color: .accentColor)
        case .closed: Chip(text: "Closed", symbol: "lock", color: .secondary)
        }
    }
}

/// Labels get a stable color from their name.
struct LabelChip: View {
    let label: String
    var body: some View {
        Chip(text: label, color: Color(nsColor: Theme.labelColor(label)))
    }
}

/// "CW-a3f9" in monospace, copyable.
struct TaskIDText: View {
    let id: String
    var body: some View {
        Text(id)
            .font(Theme.Font.monoSmall.weight(.medium))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

// MARK: Pickers

/// Assignee choices in one order everywhere: Unassigned, Me, then everyone
/// else. `item` builds one entry (a menu button or a tagged picker row);
/// `email` is nil for Unassigned.
struct AssigneeOptions<Item: View>: View {
    let store: CoworkStore
    @ViewBuilder let item: (_ email: String?, _ title: String, _ icon: Image) -> Item

    var body: some View {
        item(nil, L("Unassigned"), Image(systemName: "person.crop.circle.badge.questionmark"))
        if !store.me.email.isEmpty {
            item(store.me.email, String(localized: "Me (\(store.me.displayName))"), menuPersonIcon(store.me))
        }
        let others = store.others
        if !others.isEmpty {
            Divider()
            ForEach(others) { p in item(p.email, p.displayName, menuPersonIcon(p)) }
        }
    }
}

/// Picker of assignees; the selection is an email, "" for Unassigned.
struct AssigneePicker: View {
    let title: String
    let store: CoworkStore
    @Binding var selection: String

    var body: some View {
        Picker(LocalizedStringKey(title), selection: $selection) {
            AssigneeOptions(store: store) { email, title, icon in
                Label { Text(title) } icon: { icon }.tag(email ?? "")
            }
        }
    }
}

/// Picker of task statuses, each with its colored icon.
struct StatusPicker: View {
    let title: String
    @Binding var selection: TaskStatus

    var body: some View {
        Picker(LocalizedStringKey(title), selection: $selection) {
            ForEach(TaskStatus.allCases, id: \.self) { $0.menuLabel.tag($0) }
        }
    }
}

extension TaskStatus {
    /// Title with the colored status icon, for menus and pickers.
    var menuLabel: some View {
        Label { Text(label) } icon: { menuSymbol(symbol, color) }
    }
}
