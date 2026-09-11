@testable import Mimi
import Testing

/// Tests the pure sidebar status mapping: the session capsule's
/// title/icon/gradient-choice/disabled gate per phase (including the
/// model-check gating that must not disable Stop), the ASR dot tone, and
/// the translation detail line with its fallback-latch override.
@Suite("Sidebar status mapping")
struct SidebarStatusTests {

    // MARK: - Session capsule

    @Test("idle-family phases offer Start and are enabled once the model check settles")
    func startPhases() {
        for phase in [SessionPhase.idle, .needsModel, .failed("boom")] {
            let status = SidebarStatus.map(phase: phase, isCheckingModel: false)

            #expect(!status.isLiveSession)
            #expect(status.sessionTitle == "Start session")
            #expect(status.sessionIcon == "play.fill")
            #expect(!status.isSessionDisabled)
        }
    }

    @Test("transition phases offer Start but disable the capsule")
    func transitionPhases() {
        for phase in [SessionPhase.starting, .stopping] {
            let status = SidebarStatus.map(phase: phase, isCheckingModel: false)

            #expect(!status.isLiveSession)
            #expect(status.sessionTitle == (phase == .starting ? "Starting…" : "Stopping…"))
            #expect(status.sessionIcon == "play.fill")
            #expect(status.isSessionDisabled)
        }
    }

    @Test("live phases offer Stop and stay reachable")
    func livePhases() {
        for phase in [SessionPhase.running, .sourceLost] {
            let status = SidebarStatus.map(phase: phase, isCheckingModel: false)

            #expect(status.isLiveSession)
            #expect(status.sessionTitle == "Stop session")
            #expect(status.sessionIcon == "stop.fill")
            #expect(!status.isSessionDisabled)
        }
    }

    @Test("an in-flight model check gates Start but never Stop")
    func modelCheckGating() {
        for phase in [SessionPhase.idle, .needsModel, .failed("boom")] {
            #expect(
                SidebarStatus.map(phase: phase, isCheckingModel: true).isSessionDisabled
            )
        }
        #expect(
            SidebarStatus.map(phase: .running, isCheckingModel: true).isSessionDisabled == false
        )
        #expect(
            SidebarStatus.map(phase: .sourceLost, isCheckingModel: true).isSessionDisabled == false
        )
    }

    // MARK: - ASR dot

    @Test("the ASR dot follows the phase's tone")
    func asrDotTone() {
        #expect(SidebarStatus.map(phase: .running, isCheckingModel: false).asrDot == .green)
        #expect(SidebarStatus.map(phase: .starting, isCheckingModel: false).asrDot == .yellow)
        #expect(SidebarStatus.map(phase: .stopping, isCheckingModel: false).asrDot == .yellow)
        #expect(SidebarStatus.map(phase: .sourceLost, isCheckingModel: false).asrDot == .red)
        #expect(SidebarStatus.map(phase: .failed("x"), isCheckingModel: false).asrDot == .red)
        #expect(SidebarStatus.map(phase: .idle, isCheckingModel: false).asrDot == .neutral)
        #expect(SidebarStatus.map(phase: .needsModel, isCheckingModel: false).asrDot == .neutral)
    }

    // MARK: - Translation detail

    @Test("healthy states name the active engine")
    func healthyEngineLabels() {
        #expect(
            SidebarStatus.translationDetail(
                status: .ready, activeEngine: .apple, fallbackActive: false
            ) == "On-device"
        )
        #expect(
            SidebarStatus.translationDetail(
                status: .ready, activeEngine: .external, fallbackActive: false
            ) == "External"
        )
        #expect(
            SidebarStatus.translationDetail(
                status: .translating, activeEngine: .external, fallbackActive: false
            ) == "External"
        )
        #expect(
            SidebarStatus.translationDetail(
                status: .idle, activeEngine: .apple, fallbackActive: false
            ) == "On-device"
        )
    }

    @Test("the fallback latch and degraded both read On-device (fallback)")
    func fallbackLabels() {
        #expect(
            SidebarStatus.translationDetail(
                status: .ready, activeEngine: .apple, fallbackActive: true
            ) == "On-device (fallback)"
        )
        #expect(
            SidebarStatus.translationDetail(
                status: .degraded("degraded", .permanent),
                activeEngine: .apple, fallbackActive: false
            ) == "On-device (fallback)"
        )
    }

    @Test("unavailable reads Unavailable; retrying stays on the external engine")
    func failureLabels() {
        #expect(
            SidebarStatus.translationDetail(
                status: .unavailable("failed", .permanent),
                activeEngine: .external, fallbackActive: false
            ) == "Unavailable"
        )
        #expect(
            SidebarStatus.translationDetail(
                status: .retrying("2 retries left"),
                activeEngine: .external, fallbackActive: false
            ) == "External"
        )
    }

    @Test("the latch never masks failure — unavailable and retrying win over it")
    func latchDoesNotMaskFailure() {
        #expect(
            SidebarStatus.translationDetail(
                status: .unavailable("failed", .permanent),
                activeEngine: .apple, fallbackActive: true
            ) == "Unavailable"
        )
        #expect(
            SidebarStatus.translationDetail(
                status: .retrying("2 retries left"),
                activeEngine: .external, fallbackActive: true
            ) == "External"
        )
    }

    // MARK: - Dot tone bridge

    @Test("DotTone mirrors TranslationPill.Tone one-to-one")
    func pillToneBridge() {
        #expect(SidebarStatus.DotTone(TranslationPill.Tone.green) == .green)
        #expect(SidebarStatus.DotTone(TranslationPill.Tone.yellow) == .yellow)
        #expect(SidebarStatus.DotTone(TranslationPill.Tone.red) == .red)
        #expect(SidebarStatus.DotTone(TranslationPill.Tone.neutral) == .neutral)
    }
}
