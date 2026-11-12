import AppKit
import SwiftUI

/// A one-point line between two panels that resizes one of them when
/// dragged, like an NSSplitView divider. `width` is that panel's width; it
/// is the panel on the left unless `panelOnLeft` is false.
struct ResizeDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    var panelOnLeft = true
    @State private var startWidth: Double?

    /// The area that takes the drag, wider than the line.
    private static let grip: CGFloat = 7

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: Self.grip)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = startWidth ?? width
                                startWidth = start
                                let delta = panelOnLeft ? drag.translation.width : -drag.translation.width
                                width = min(max(start + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
