import SwiftUI

/// The connection pill in the status-bar footer, derived purely from the
/// translation status × active engine. The HUD stays clean — the pill lives
/// in the main window footer only.
struct TranslationPill: Equatable {
    enum Tone: Equatable {
        case green, yellow, red, neutral
    }

    let tone: Tone
    /// "On-device" or "External" (the engine label for red pills).
    let label: String

    static func map(
        status: TranslationStatus,
        activeEngine: ActiveTranslationEngine
    ) -> TranslationPill {
        switch status {
        case .ready, .translating:
            TranslationPill(tone: .green, label: engineLabel(activeEngine))
        case .retrying:
            // Retries only happen on external engines.
            TranslationPill(tone: .yellow, label: "External")
        case .degraded:
            // Degraded means latched onto Apple on-device.
            TranslationPill(tone: .yellow, label: "On-device")
        case .unavailable:
            TranslationPill(tone: .red, label: engineLabel(activeEngine))
        case .idle:
            TranslationPill(tone: .neutral, label: "")
        }
    }

    private static func engineLabel(_ engine: ActiveTranslationEngine) -> String {
        engine == .external ? "External" : "On-device"
    }
}
