import SwiftUI

// Button styles and small shared buttons.

/// The one button family used inside panels (the toolbar and list rows use
/// the flat `HoverFillStyle`):
/// - `.primary`: filled with the tint, white text. The main action of a block
///   (New Task, Commit, Approve). Use at most one or two per block.
/// - `.secondary`: small bordered button, tinted text on a soft tinted fill.
///   Without a tint it is neutral (label color, separator border).
/// - Inline text actions use `.buttonStyle(.link)`.
struct ActionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary
    var tint: Color?

    static func primary(_ tint: Color = .accentColor) -> ActionButtonStyle { .init(kind: .primary, tint: tint) }
    static func secondary(_ tint: Color? = nil) -> ActionButtonStyle { .init(kind: .secondary, tint: tint) }

    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(label: configuration.label, kind: kind, tint: tint, pressed: configuration.isPressed)
    }
}

/// Draws the `ActionButtonStyle` look. Also used directly as the label of
/// menus (`actionButtonLabel`), which can't take a custom button style.
private struct ActionButtonBody<Label: View>: View {
    let label: Label
    let kind: ActionButtonStyle.Kind
    let tint: Color?
    var pressed = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
        label
            .labelStyle(ActionLabelStyle())
            .font(Theme.Font.small.weight(kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Space.m + Theme.Space.xs)
            .frame(minHeight: Theme.Metrics.buttonHeight)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: Theme.Metrics.hairline))
            .overlay(shape.fill(Color.black.opacity(pressed ? 0.12 : 0)))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.45)
            .fixedSize()
            .onHover { hovering = $0 }
    }

    private var color: Color { tint ?? .primary }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: tint?.readableTint(scheme) ?? .primary
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: (tint ?? .accentColor).opacity(hovering && enabled ? 0.88 : 1)
        case .secondary: tint == nil
            ? color.opacity(hovering && enabled ? 0.16 : 0.05)
            : color.opacity(hovering && enabled ? Theme.Tint.chip + 0.07 : Theme.Tint.chip)
        }
    }

    private var border: Color {
        switch kind {
        case .primary: .clear
        case .secondary: tint == nil ? Color(nsColor: .separatorColor) : .clear  // tinted: the fill is enough
        }
    }
}

/// Plain button with a soft fill while hovered or pressed. `.row` for
/// clickable list rows; `.chrome()` for the flat toolbar buttons, with a
/// little padding and rounded corners. Dimmed when disabled.
struct HoverFillStyle: ButtonStyle {
    var hover = 0.05
    var pressed = 0.10
    var radius: CGFloat = 0
    var padding = EdgeInsets()

    static let row = HoverFillStyle()

    static func chrome(horizontalPadding: CGFloat = Theme.Space.s) -> HoverFillStyle {
        HoverFillStyle(hover: 0.08, pressed: 0.16, radius: Theme.Radius.control,
                       padding: EdgeInsets(top: Theme.Space.xs, leading: horizontalPadding,
                                           bottom: Theme.Space.xs, trailing: horizontalPadding))
    }

    func makeBody(configuration: Configuration) -> some View {
        HoverFillBody(configuration: configuration, style: self)
    }

    private struct HoverFillBody: View {
        let configuration: Configuration
        let style: HoverFillStyle
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .padding(style.padding)
                .background(RoundedRectangle(cornerRadius: style.radius).fill(Color.primary.opacity(fill)))
                .foregroundStyle(enabled ? .primary : .tertiary)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var fill: Double {
            guard enabled else { return 0 }
            if configuration.isPressed { return style.pressed }
            return hovering ? style.hover : 0
        }
    }
}

/// Icon and title close together, icon a little smaller than the text.
private struct ActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Space.s) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title
        }
    }
}

extension View {
    /// The `ActionButtonStyle` look for a menu's label. Use with
    /// `.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)`.
    func actionButtonLabel(_ kind: ActionButtonStyle.Kind = .secondary, tint: Color? = nil) -> some View {
        ActionButtonBody(label: self, kind: kind, tint: tint)
    }
}

/// Small borderless "+" in a header (sidebar sections, board columns).
/// `size` is the click area; `weight` matches the header's text.
struct HeaderAddButton: View {
    let help: String
    var size = Theme.Metrics.iconWidth
    var weight: Font.Weight = .medium
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: weight))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(Text(ui: help))
    }
}
