import GitCoworkCore
import SwiftUI

extension CIState {
    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "clock.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: Theme.Status.success
        case .failure: Theme.Status.error
        case .pending: Theme.Status.warning
        }
    }

    var title: String {
        switch self {
        case .success: L("Passed")
        case .failure: L("Failed")
        case .pending: L("Running")
        }
    }
}

extension CIResult {
    /// "1 failed, 4 passed".
    var summary: String {
        var parts: [String] = []
        let failed = count(.failure), running = count(.pending), passed = count(.success)
        if failed > 0 { parts.append(String(localized: "\(failed) failed")) }
        if running > 0 { parts.append(String(localized: "\(running) running")) }
        if passed > 0 { parts.append(String(localized: "\(passed) passed")) }
        return parts.joined(separator: ", ")
    }
}

/// CI state icon for sidebar rows. Empty when nothing is known.
struct CIIcon: View {
    let state: CIState?

    var body: some View {
        if let state {
            Image(systemName: state.symbol)
                .font(.system(size: SidebarStyle.iconSize))
                .foregroundStyle(state.color)
                .help("CI: \(state.title)")
        }
    }
}

struct CIChip: View {
    let state: CIState
    var body: some View { Chip(text: state.title, symbol: state.symbol, color: state.color) }
}

struct PullChip: View {
    let pull: HostPull
    var body: some View {
        if pull.isDraft {
            Chip(text: "Draft", symbol: "pencil", color: .secondary)
        } else {
            Chip(text: "Open", symbol: "circle", color: .accentColor)
        }
    }
}
