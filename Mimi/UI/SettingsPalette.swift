import SwiftUI

/// Settings-local adaptive palette: warm paper light appearance and sakura
/// dark appearance. Resolves through the drawing appearance,
/// which the Appearance setting drives via `.preferredColorScheme`.
enum Palette {
    // Surfaces
    static let window = Color(light: 0xFAF7F2, dark: 0x12101A)
    static let headerBar = Color(light: 0xFAF7F2, dark: 0x171320)
    static let divider = Color(
        light: NSColor(hex: 0xE9E2D8), dark: NSColor.white.withAlphaComponent(0.06)
    )
    static let cardFill = Color(
        light: .white, dark: NSColor.white.withAlphaComponent(0.045)
    )
    static let cardStroke = Color(
        light: NSColor(hex: 0xE9E2D8), dark: NSColor.white.withAlphaComponent(0.07)
    )
    static let cardShadow = Color(
        light: NSColor(hex: 0x2A241E).withAlphaComponent(0.05), dark: .clear
    )
    static let fieldFill = Color(
        light: NSColor(hex: 0xF0EAE1), dark: NSColor.white.withAlphaComponent(0.05)
    )
    static let fieldStroke = Color(
        light: NSColor(hex: 0xE9E2D8), dark: NSColor.white.withAlphaComponent(0.09)
    )
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

    // Text
    static let primaryText = Color(light: 0x2A241E, dark: 0xFFFFFF)
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
    static let accent = Color(light: 0xFF6B5E, dark: 0xFF6E9C)
    static let accentViolet = Color(light: 0xFF6B5E, dark: 0xB36BFF)
    static let engineText = Color(light: 0xFF6B5E, dark: 0x9FE8DF)
    static let statusGreen = Color(light: 0x15803D, dark: 0x4ADE80)
    static let statusRed = Color(light: 0xC21F30, dark: 0xFF8A93)
}

// MARK: - Shared card pieces

extension View {
    /// Stacked-card surface used by every settings card.
    func settingsCardBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Palette.cardStroke)
                )
                .shadow(color: Palette.cardShadow, radius: 8, y: 3)
        )
    }

    /// Kicker label at the top of a settings card.
    func settingsCardLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Palette.label)
            .kerning(1.2)
    }

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
