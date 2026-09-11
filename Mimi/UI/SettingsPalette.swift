import SwiftUI

/// Settings-local adaptive palette: warm paper light appearance and sakura
/// dark appearance. Resolves through the drawing appearance,
/// which the Appearance setting drives via `.preferredColorScheme`.
enum Palette {
    // Surfaces
    static let window = SharedTokens.window
    static let headerBar = Color(light: 0xFAF7F2, dark: 0x171320)
    static let divider = SharedTokens.divider
    static let cardFill = SharedTokens.cardFill
    static let cardStroke = SharedTokens.cardStroke
    static let cardShadow = Color(
        light: NSColor(hex: 0x2A241E).withAlphaComponent(0.05), dark: .clear
    )
    static let fieldFill = Color(
        light: NSColor(hex: 0xF0EAE1), dark: NSColor.white.withAlphaComponent(0.05)
    )
    static let fieldStroke = Color(
        light: NSColor(hex: 0xE9E2D8), dark: NSColor.white.withAlphaComponent(0.09)
    )
    /// Settings tile fill. Dark density is deliberately stronger than
    /// `Theme.tileFill` (6% vs 4%): these tiles sit inside an elevated card,
    /// where a lighter wash would disappear.
    static let tileFill = Color(
        light: NSColor(hex: 0xF0EAE1), dark: NSColor.white.withAlphaComponent(0.06)
    )
    static let pillFill = Color(
        light: NSColor(hex: 0xF0EAE1), dark: NSColor.white.withAlphaComponent(0.08)
    )
    static let segmentTrack = Color(
        light: NSColor(hex: 0xF0EAE1), dark: NSColor.white.withAlphaComponent(0.07)
    )
    static let segmentFill = Color(
        light: NSColor(hex: 0xFF6B5E), dark: NSColor(hex: 0xFF6E9C)
    )

    /// Text
    static let primaryText = SharedTokens.primaryText
    /// Settings detail text. Dark density is deliberately stronger than
    /// `Theme.secondaryText` (60% vs 45%) for the settings hierarchy.
    static let secondaryText = Color(
        light: NSColor(hex: 0x8A8177), dark: NSColor.white.withAlphaComponent(0.6)
    )
    static let mutedText = Color(
        light: NSColor(hex: 0xB3A99C), dark: NSColor.white.withAlphaComponent(0.45)
    )
    static let label = Color(
        light: NSColor(hex: 0xB3A99C), dark: NSColor.white.withAlphaComponent(0.4)
    )

    // Accent
    static let accent = SharedTokens.accent
    static let accentViolet = SharedTokens.brandViolet
    static let engineText = Color(light: 0xFF6B5E, dark: 0x9FE8DF)
    static let statusGreen = SharedTokens.statusGreen
    static let statusRed = Color(light: 0xC21F30, dark: 0xFF8A93)
}

// MARK: - Shared card pieces

extension View {
    /// 1pt hairline between rows inside a settings card.
    func settingsDivider() -> some View {
        Rectangle().fill(Palette.divider).frame(height: 1)
    }

    /// Shared rounded field treatment for key/model text fields.
    func settingsFieldBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.fieldFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Palette.fieldStroke)
                )
        )
    }
}

/// Capsule action button used across the settings cards. The prominent
/// variant fills with the accent; hover highlights pink (a white wash on the
/// accent fill, a pink wash on neutral pills).
struct SettingsPill: View {
    let label: String
    var prominent = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Palette.primaryText.opacity(0.75))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(Capsule().fill(prominent ? Palette.accent : Palette.pillFill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .hoverHighlight(
            Capsule(), isEnabled: isEnabled,
            tint: prominent ? .white : Palette.accent, opacity: prominent ? 0.15 : 0.12
        )
    }
}
