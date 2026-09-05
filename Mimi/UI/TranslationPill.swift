import SwiftUI

/// The connection pill in the status-bar footer, derived purely from the
/// translation status × active engine × fallback latch. The HUD stays clean —
/// the pill lives in the main window footer only.
struct TranslationPill: Equatable {
    enum Tone: Equatable {
        case green, yellow, red, neutral
    }

    let tone: Tone
    /// "On-device" or "External" — the engine label for every status.
    let label: String

    static func map(
        status: TranslationStatus,
        activeEngine: ActiveTranslationEngine,
        fallbackActive: Bool = false
    ) -> TranslationPill {
        switch status {
        case .ready, .translating:
            // Latched on Apple after an external failure: degraded, not healthy.
            TranslationPill(
                tone: fallbackActive ? .yellow : .green,
                label: engineLabel(activeEngine)
            )
        case .retrying:
            // Retries only happen on external engines.
            TranslationPill(tone: .yellow, label: "External")
        case .degraded:
            // Degraded means latched onto Apple on-device.
            TranslationPill(tone: .yellow, label: "On-device")
        case .unavailable:
            TranslationPill(tone: .red, label: engineLabel(activeEngine))
        case .idle:
            TranslationPill(tone: .neutral, label: engineLabel(activeEngine))
        }
    }

    private static func engineLabel(_ engine: ActiveTranslationEngine) -> String {
        engine == .external ? "External" : "On-device"
    }
}
