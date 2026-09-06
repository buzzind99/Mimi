import SwiftUI

/// Hover highlight for buttons: a faint text-tinted wash over `shape` while
/// the pointer is inside, suppressed while `isEnabled` is false.
struct HoverHighlight<S: Shape>: ViewModifier {
    let shape: S
    var isEnabled: Bool = true

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.fill(Theme.primaryText.opacity(hovering && isEnabled ? 0.07 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight<S: Shape>(_ shape: S, isEnabled: Bool = true) -> some View {
        modifier(HoverHighlight(shape: shape, isEnabled: isEnabled))
    }
}
