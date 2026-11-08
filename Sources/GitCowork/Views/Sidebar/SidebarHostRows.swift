import GitCoworkCore
import SwiftUI

/// Open pull request: [CI or pull icon] #12 Title ……… Draft.
struct SidebarPullRow: View {
    let pull: HostPull
    let ci: CIState?

    var body: some View {
        SidebarRowLayout {
            SidebarIcon(symbol: ci?.symbol ?? "arrow.triangle.pull", color: ci?.color ?? .secondary)
            Text(verbatim: "#\(pull.number)")
                .font(Theme.Font.monoSmall)
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(pull.title).truncationMode(.tail)
            Spacer(minLength: Theme.Space.s)
            if pull.isDraft {
                Text("Draft")
                    .font(Theme.Font.small)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .help("#\(pull.number) \(pull.title)\n\(pull.branch) → \(pull.base) · \(pull.author)")
    }
}
