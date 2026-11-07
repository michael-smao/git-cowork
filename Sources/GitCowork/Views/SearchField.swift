import SwiftUI

/// Rounded search or filter field: icon, text, optional trailing note (a
/// count), clear button. Esc clears it. `compact` makes it as tall as the
/// action buttons, for bars that hold both.
struct SearchField<Trailing: View>: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var symbol = "magnifyingglass"
    var compact = false
    var clearHelp: LocalizedStringKey = "Clear search"
    /// Runs after Esc cleared the text.
    var onExit: () -> Void = {}
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focus)
                .onExitCommand { text = ""; onExit() }
            trailing
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(clearHelp)
            }
        }
        .font(compact ? Theme.Font.small : Theme.Font.body)
        .padding(.horizontal, Theme.Space.m)
        .frame(height: compact ? Theme.Metrics.buttonHeight : Theme.Metrics.rowHeight)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(focus.wrappedValue ? Color.accentColor.opacity(0.6) : .clear)
        }
    }
}

extension SearchField where Trailing == EmptyView {
    init(_ prompt: LocalizedStringKey, text: Binding<String>, focus: FocusState<Bool>.Binding,
         compact: Bool = false, clearHelp: LocalizedStringKey = "Clear search", onExit: @escaping () -> Void = {}) {
        self.init(prompt: prompt, text: text, focus: focus, compact: compact, clearHelp: clearHelp, onExit: onExit) {
            EmptyView()
        }
    }
}
