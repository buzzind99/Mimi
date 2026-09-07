import SwiftUI

/// Capsule segmented picker shared by the sidebar's annotation and cursor
/// mode sections: pill segments over a card fill, selected segment painted
/// accent, hover wash per segment.
struct ModePicker<M: Equatable & Identifiable>: View {
    let help: String
    let modes: [M]
    @Binding var selection: M
    let label: (M) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes) { mode in
                segment(label(mode), isSelected: mode == selection) { selection = mode }
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.cardFill))
        .help(help)
    }

    private func segment(
        _ text: String, isSelected: Bool, onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            Text(text)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        Capsule().fill(Theme.accentPink)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverHighlight(Capsule())
    }
}
