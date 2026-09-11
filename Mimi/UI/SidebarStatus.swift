import SwiftUI

/// Pure phase → presentation mapping for the sidebar's status affordances —
/// the session capsule (title, icon, gradient choice, disabled gate) and the
/// ASR engine dot's tone. Mirrors the `TranslationPill.map` precedent: the
/// view renders the mapping, tests pin it.
struct SidebarStatus: Equatable {
    /// Status-dot tone, shared by the ASR and translation rows.
    enum DotTone: Equatable {
        case green, yellow, red, neutral

        /// Same scale as `TranslationPill.Tone` — the translation row reads
        /// the pill mapping and converts.
        init(_ tone: TranslationPill.Tone) {
            switch tone {
            case .green: self = .green
            case .yellow: self = .yellow
            case .red: self = .red
            case .neutral: self = .neutral
            }
        }
    }

    /// Stop-capsule states: a live session (or one whose capture source was
    /// lost) offers Stop; everything else offers Start.
    let isLiveSession: Bool
    let sessionTitle: String
    let sessionIcon: String
    /// While model discovery is in flight Start is gated (`isCheckingModel`);
    /// Stop must stay reachable from a live session.
    let isSessionDisabled: Bool
    let asrDot: DotTone

    static func map(phase: SessionPhase, isCheckingModel: Bool) -> SidebarStatus {
        let isLive = phase == .running || phase == .sourceLost
        let title = switch phase {
        case .running, .sourceLost: "Stop session"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .idle, .needsModel, .failed: "Start session"
        }
        let dot: DotTone = switch phase {
        case .running: .green
        case .starting, .stopping: .yellow
        case .sourceLost, .failed: .red
        case .idle, .needsModel: .neutral
        }
        return SidebarStatus(
            isLiveSession: isLive,
            sessionTitle: title,
            sessionIcon: isLive ? "stop.fill" : "play.fill",
            isSessionDisabled: phase == .starting || phase == .stopping
                || (isCheckingModel && !isLive),
            asrDot: dot
        )
    }

    /// The translation row's detail line. The latched Apple fallback stays
    /// visible after the fresh Apple run publishes `.ready` — otherwise
    /// "On-device (fallback)" would flash for under a second and the card
    /// would read as healthy green. The latch never masks failure:
    /// `.unavailable` wins over it, and `.retrying` (external-only) names
    /// the engine — mirroring the dot tones from `TranslationPill.map`.
    static func translationDetail(
        status: TranslationStatus,
        activeEngine: ActiveTranslationEngine,
        fallbackActive: Bool
    ) -> String {
        switch status {
        case .unavailable: "Unavailable"
        case .degraded: "On-device (fallback)"
        case .retrying: "External"
        case .ready, .translating, .idle:
            fallbackActive
                ? "On-device (fallback)"
                : (activeEngine == .apple ? "On-device" : "External")
        }
    }
}
