import SwiftUI

/// Hover highlight for buttons: a faint wash of `tint` over `shape` while
/// the pointer is inside, suppressed while `isEnabled` is false.
struct HoverHighlight<S: Shape>: ViewModifier {
    let shape: S
    var isEnabled: Bool = true
    var tint: Color = Theme.primaryText
    var opacity: Double = 0.07

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.fill(tint.opacity(hovering && isEnabled ? opacity : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight(
        _ shape: some Shape, isEnabled: Bool = true, tint: Color = Theme.primaryText,
        opacity: Double = 0.07
    ) -> some View {
        modifier(HoverHighlight(shape: shape, isEnabled: isEnabled, tint: tint, opacity: opacity))
    }
}
