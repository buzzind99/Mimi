import AppKit
import SwiftUI

extension Color {
    /// 0xRRGGBB initializer used by the theme tokens and view-local accents.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Appearance-adaptive color: resolves a light and a dark value through
    /// the drawing appearance, which the Appearance setting drives
    /// via `.preferredColorScheme` at the window root.
    init(light: UInt32, dark: UInt32) {
        self.init(
            light: NSColor(hex: light),
            dark: NSColor(hex: dark)
        )
    }

    /// Adaptive variant for opacity tokens (white overlays on the dark
    /// palette invert to black overlays on light surfaces).
    init(light: NSColor, dark: NSColor) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Main-window design tokens. Light values mirror the Settings warm-paper
/// palette (`Palette` in SettingsPalette.swift): cream surfaces, warm-brown
/// text, coral accent. Dark values use the matching sakura dark appearance.
/// Centralized here so tokens stay tweakable without touching view code.
enum Theme {

    // MARK: Surfaces

    /// Transcript pane background.
    static let window = Color(light: 0xFAF7F2, dark: 0x12101A)
    /// Sidebar background.
    static let sidebar = Color(light: 0xFAF7F2, dark: 0x171320)
    /// Live strip background.
    static let liveStrip = Color(light: 0xF0EAE1, dark: 0x1B1626)
    /// Toast card background.
    static let toastBackground = Color(light: 0xFFFFFF, dark: 0x241522)
    /// Jump-button fill (circular scroll affordances).
    static let jumpButtonBackground = Color(light: 0xFFFFFF, dark: 0x241522)
    /// Jump-button circle stroke: white 12% on dark, black 12% on light.
    static let jumpButtonStroke = Color(
        light: NSColor.black.withAlphaComponent(0.12),
        dark: NSColor.white.withAlphaComponent(0.12)
    )

    // MARK: Strokes & fills

    /// Card fill: white 4.5% on dark, solid white (settings card fill) on light.
    static let cardFill = Color(
        light: NSColor.white,
        dark: NSColor.white.withAlphaComponent(0.045)
    )
    /// Card stroke: settings hairline `#E9E2D8` on light, white 7% on dark.
    static let cardStroke = Color(
        light: NSColor(hex: 0xE9E2D8),
        dark: NSColor.white.withAlphaComponent(0.07)
    )
    /// 1pt separators (sidebar divider, live-strip top edge).
    static let divider = Color(
        light: NSColor(hex: 0xE9E2D8),
        dark: NSColor.white.withAlphaComponent(0.06)
    )
    /// Inner tile fill (scale stepper middle, toast dismiss button).
    static let tileFill = Color(
        light: NSColor(hex: 0xF0EAE1),
        dark: NSColor.white.withAlphaComponent(0.04)
    )

    // MARK: Text

    /// JP transcript text (primary line).
    static let jpText = Color(light: 0x2A241E, dark: 0xF5F3FA)
    /// Generic primary text.
    static let primaryText = Color(light: 0x2A241E, dark: 0xFFFFFF)
    /// Labels and detail lines: warm gray `#8A8177` on light, white 45% on dark.
    static let secondaryText = Color(
        light: NSColor(hex: 0x8A8177),
        dark: NSColor.white.withAlphaComponent(0.45)
    )
    /// Gutter timestamps: white 35% on dark, muted `#B3A99C` on light.
    static let gutterText = Color(
        light: NSColor(hex: 0xB3A99C),
        dark: NSColor.white.withAlphaComponent(0.35)
    )

    // MARK: Accents

    /// Accent (reading-aid selected pill, jump-button glyphs, brand): settings
    /// coral `#FF6B5E` on light, sakura pink on dark.
    static let accentPink = Color(light: 0xFF6B5E, dark: 0xFF6E9C)
    /// Brand gradient's second stop — flat coral on light (mirrors the
    /// settings header mark), violet on dark.
    static let brandViolet = Color(light: 0xFF6B5E, dark: 0xB36BFF)
    /// Inline romaji / furigana reading annotations.
    static let annotationPink = Color(light: 0xB33459, dark: 0xFF9DBB)
    /// Translation text.
    static let translationTeal = Color(light: 0x0E7C74, dark: 0x9FE8DF)
    /// Notice pill fill: solid teal, light deep teal and dark pale mint.
    static let noticeFill = Color(light: 0x0E7C74, dark: 0x9FE8DF)
    /// Notice pill text: white on the deep light fill, dark teal ink on the
    /// pale dark fill.
    static let noticeText = Color(light: 0xFFFFFF, dark: 0x0B2E2B)
    /// LIVE indicator (dot + label): settings status red on light.
    static let liveRed = Color(light: 0xC21F30, dark: 0xFF4D5E)
    /// Engine-status dots (green = running, yellow = transitioning).
    static let dotGreen = Color(light: 0x15803D, dark: 0x4ADE80)
    static let dotYellow = Color(light: 0xB45309, dark: 0xFBBF24)

    // MARK: Toast

    /// Red-class toast border: `#FF5F6E` @35% on dark, deepened on light.
    static let toastRedBorder = Color(
        light: NSColor(hex: 0xC21F30).withAlphaComponent(0.5),
        dark: NSColor(hex: 0xFF5F6E).withAlphaComponent(0.35)
    )
    /// Yellow-class toast border: `#FBBF24` @35% on dark, deepened on light.
    static let toastYellowBorder = Color(
        light: NSColor(hex: 0x92610A).withAlphaComponent(0.5),
        dark: NSColor(hex: 0xFBBF24).withAlphaComponent(0.35)
    )
    /// Red-class toast icon tint.
    static let toastRedIcon = Color(light: 0xC21F30, dark: 0xFF8A93)

    // MARK: Gradients

    enum Gradients {
        /// Brand mark circle (`#FF6E9C → #B36BFF`, corner to corner).
        static let brand = LinearGradient(
            colors: [Theme.accentPink, Theme.brandViolet],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        /// Translation row's 3pt capsule bar (`#5EEAD4 → #38BDF8`, top→bottom).
        static let translationBar = LinearGradient(
            colors: [Color(light: 0x0D9488, dark: 0x5EEAD4), Color(light: 0x0284C7, dark: 0x38BDF8)],
            startPoint: .top, endPoint: .bottom
        )
        /// "Stop session" capsule (coral `#FF6B5E → #E0483C` on light,
        /// `#FF6E9C → #E05585` on dark, leading→trailing).
        static let stop = LinearGradient(
            colors: [Color(light: 0xFF6B5E, dark: 0xFF6E9C), Color(light: 0xE0483C, dark: 0xE05585)],
            startPoint: .leading, endPoint: .trailing
        )
        /// "Start session" capsule (`#2DD4BF → #38BDF8`, leading→trailing).
        static let start = LinearGradient(
            colors: [Color(light: 0x0D9488, dark: 0x2DD4BF), Color(light: 0x0284C7, dark: 0x38BDF8)],
            startPoint: .leading, endPoint: .trailing
        )
        /// Audio meter bars (`#5EEAD4 → #38BDF8`, top→bottom).
        static let audioMeter = LinearGradient(
            colors: [Theme.meterTeal, Theme.meterBlue], startPoint: .top, endPoint: .bottom
        )
    }

    /// Audio meter bar colors (also the translation bar's gradient stops).
    static let meterTeal = Color(light: 0x0D9488, dark: 0x5EEAD4)
    static let meterBlue = Color(light: 0x0284C7, dark: 0x38BDF8)
}
