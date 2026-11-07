import GitCoworkCore
import SwiftUI

// Sidebar rows for tasks, reviews and the team.

/// One of my tasks: [status icon] CW-a3f9 Title.
struct SidebarTaskRow: View {
    let task: CoworkTask

    var body: some View {
        SidebarRowLayout {
            SidebarIcon(symbol: task.status.symbol, color: task.status.color)
            Text(task.id)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(task.title).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help("\(task.id) · \(task.status.label)\n\(task.title)")
    }
}

/// Review request: [overall verdict icon] branch ……… requester / approvals.
struct SidebarReviewRow: View {
    let review: ReviewRequest
    /// I'm asked and haven't answered.
    let waiting: Bool
    let requester: TeamMember?

    var body: some View {
        let overall = review.overall
        SidebarRowLayout {
            SidebarIcon(symbol: overall.symbol, color: waiting ? .accentColor : overall.color)
            Text(review.branch)
                .fontWeight(waiting ? .semibold : .regular)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s)
            SidebarTrailing {
                if waiting {
                    PersonAvatar(person: requester, size: SidebarStyle.avatarSize)
                } else {
                    Text(verbatim: "\(approvals)/\(review.reviewers.count)")
                        .font(Theme.Font.small.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(approvals) of \(review.reviewers.count) approved")
                }
            }
        }
        .help(waiting
              ? "\(requester?.name ?? review.requester) asked you to review \(review.branch)\n\(review.title)"
              : "\(review.branch): \(overall.title)\n\(review.title)")
    }

    private var approvals: Int { review.reviewers.values.filter { $0 == .approved }.count }
}

/// Team member: [avatar] Name @handle.
struct SidebarPersonRow: View {
    let person: TeamMember
    let isMe: Bool

    var body: some View {
        SidebarRowLayout {
            Avatar(name: person.displayName, email: person.email,
                   size: SidebarStyle.avatarSize)
                .frame(width: Theme.Metrics.iconWidth)
            Text(person.displayName)
            if !person.handle.isEmpty {
                Text(verbatim: "@" + person.handle)
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Theme.Space.s)
            if isMe {
                Text("you")
                    .font(Theme.Font.small)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .help("\(person.name) <\(person.email)>")
    }
}
