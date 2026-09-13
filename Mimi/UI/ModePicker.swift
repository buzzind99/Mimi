import SwiftUI

/// Capsule segmented picker shared by the sidebar's annotation/cursor mode
/// sections and the settings appearance control: pill segments over a track
/// capsule, the selected segment painted `selectedFill`, a hover wash per
/// unselected segment. The `label` closure supplies each segment's text with
/// an optional SF Symbol icon; the track/selected/unselected colors come
/// from the surface's palette (`Theme` for the sidebar, `Palette` for
/// settings).
struct ModePicker<M: Equatable & Identifiable>: View {
    let help: String
    let modes: [M]
    @Binding var selection: M
    let label: (M) -> String
    var icon: (M) -> String? = { _ in nil }
    var track: Color = Theme.cardFill
    var selectedFill: Color = Theme.accentPink
    var unselectedColor: Color = Theme.secondaryText

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes) { mode in
                segment(label(mode), icon: icon(mode), isSelected: mode == selection) {
                    selection = mode
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(track))
        .help(help)
    }

    private func segment(
        _ text: String, icon: String?, isSelected: Bool, onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(text)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.white : unselectedColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    Capsule().fill(selectedFill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverHighlight(Capsule(), isEnabled: !isSelected)
    }
}
