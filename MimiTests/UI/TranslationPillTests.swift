import Foundation
@testable import Mimi
import Testing

/// Tests the translation pill mapping: tone × engine label per status, and
/// the fallback-latch override — a latched `.ready` is degraded (yellow),
/// not healthy (green).
@Suite("TranslationPill mapping")
struct TranslationPillTests {

    @Test("healthy ready/translating on-device is green")
    func readyOnDeviceIsGreen() {
        let pill = TranslationPill.map(status: .ready, activeEngine: .apple)

        #expect(pill.tone == .green)
        #expect(pill.label == "On-device")
    }

    @Test("healthy ready/translating external is green")
    func readyExternalIsGreen() {
        let pill = TranslationPill.map(status: .translating, activeEngine: .external)

        #expect(pill.tone == .green)
        #expect(pill.label == "External")
    }

    @Test("a latched ready is yellow, not green")
    func latchedReadyIsYellow() {
        let pill = TranslationPill.map(
            status: .ready, activeEngine: .apple, fallbackActive: true
        )

        #expect(pill.tone == .yellow)
        #expect(pill.label == "On-device")
    }

    @Test("degraded is yellow on-device regardless of the latch flag")
    func degradedIsYellowOnDevice() {
        for fallbackActive in [false, true] {
            let pill = TranslationPill.map(
                status: .degraded("degraded", .permanent),
                activeEngine: .apple,
                fallbackActive: fallbackActive
            )

            #expect(pill.tone == .yellow)
            #expect(pill.label == "On-device")
        }
    }

    @Test("unavailable is red with the active engine's label, latch or not")
    func unavailableIsRed() {
        for (engine, label) in [(ActiveTranslationEngine.apple, "On-device"), (.external, "External")] {
            let pill = TranslationPill.map(
                status: .unavailable("failed", .permanent),
                activeEngine: engine,
                fallbackActive: engine == .apple
            )

            #expect(pill.tone == .red)
            #expect(pill.label == label)
        }
    }

    @Test("retrying is yellow external; idle is neutral")
    func retryingAndIdle() {
        let retrying = TranslationPill.map(status: .retrying("2 retries left"), activeEngine: .external)

        #expect(retrying.tone == .yellow)
        #expect(retrying.label == "External")

        let idle = TranslationPill.map(status: .idle, activeEngine: .apple)

        #expect(idle.tone == .neutral)
        #expect(idle.label == "On-device")
    }
}
