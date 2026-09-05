import Foundation
@testable import Mimi
import Testing

/// Tests the sidebar AUDIO-meter feed over the injected capture seam: chunks
/// arrive on the (simulated) SCK output queue, so `handleCaptureChunk` must
/// stage the RMS off-main and the 60 ms poll tick must drain it onto the
/// main-actor `AudioLevelState` — never touch it directly.
///
/// Standalone suite (folded out of `SessionControllerTests` to keep that file
/// under its lint gates); the scripted doubles mirror its fixtures.
@MainActor
@Suite("SessionController audio meter feed")
struct SessionControllerAudioMeterTests {

    private let modelURL = URL(fileURLWithPath: "/tmp/mimi-meter.gguf")
    private let chunk = AudioChunk(samples: [Float](repeating: 0.1, count: 2560), startSample: 0)

    // MARK: - Fixtures

    private func makeSUT() -> SUT {
        let audioLevel = AudioLevelState()
        let latency = LatencyState()
        let engine = ScriptedASREngine()
        let capture = ScriptedCapture()
        let controller = SessionController(
            live: LivePartialState(), latency: latency, audioLevel: audioLevel,
            translationQueue: TranslationQueue(),
            makeEngine: { _, _ in engine },
            makeCapture: { capture },
            ensurePermission: { true },
            warmUpEnabled: { false }
        )
        return SUT(controller: controller, audioLevel: audioLevel, capture: capture)
    }

    /// Pumps the main runloop in short slices for `seconds` total so the
    /// controller's scheduled timers fire, giving the main actor slots
    /// between slices to run the tasks their closures enqueue.
    private func pumpTimers(seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pumpRunLoop(seconds: 0.05)
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Condition-driven pump (same rationale as `pumpTimers(seconds:)`):
    /// assertions never hinge on a fixed delay outrunning timer-fire
    /// scheduling under load. Returns false on timeout.
    private func pumpTimers(
        timeout: TimeInterval = 2,
        until condition: @autoclosure () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            pumpRunLoop(seconds: 0.05)
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Sync wrapper around the noasync-annotated `RunLoop.run(until:)`:
    /// `Task.sleep` does not spin the main runloop, so the scheduled
    /// poll/tick timers never fire without this deliberate pump.
    private nonisolated func pumpRunLoop(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Meter feed

    /// The pre-timer assertion is deterministic — no timers, no drain: the
    /// chunk was pushed but the ring must still be zeroed.
    @Test("chunks stage off-main; only the poll tick feeds the meter")
    func chunksReachMeterOnlyViaPollTick() async throws {
        let sut = makeSUT()
        _ = try await sut.controller.begin(modelURL: modelURL, modelID: "meter-test-GGUF")

        sut.capture.onChunk?(chunk)
        #expect(
            sut.audioLevel.levels.allSatisfy { $0 == 0 },
            "the chunk callback must not touch the main-actor meter directly"
        )

        sut.controller.startTimers()
        let surfaced = await pumpTimers(until: (sut.audioLevel.levels.last ?? 0) > 0)

        #expect(surfaced, "the poll tick must drain the staged RMS into the meter")
        #expect(abs(sut.audioLevel.dBFS + 20) < 0.01, "RMS 0.1 maps to −20 dBFS")
    }

    /// A chunk staged by a previous session (e.g. pushed between its last
    /// poll and `stop()`) must never surface in the next session's meter.
    @Test("a new begin clears any RMS staged by the previous session")
    func beginClearsStagedRMSFromPreviousSession() async throws {
        let sut = makeSUT()
        _ = try await sut.controller.begin(modelURL: modelURL, modelID: "meter-test-GGUF")
        sut.capture.onChunk?(chunk)
        await sut.controller.stop()

        _ = try await sut.controller.begin(modelURL: modelURL, modelID: "meter-test-GGUF")
        sut.controller.startTimers()
        await pumpTimers(seconds: 0.3)

        #expect(
            sut.audioLevel.levels.allSatisfy { $0 == 0 },
            "the new session's meter must start from a cleared stage"
        )
    }
}

private struct SUT {
    let controller: SessionController
    let audioLevel: AudioLevelState
    let capture: ScriptedCapture
}

private final class ScriptedASREngine: ASREngine, @unchecked Sendable {
    let isMock = true
    var onEngineError: ((String) -> Void)?
    var processedSamples = 0
    private var pushedTotal = 0

    func prepare() {}
    func openStream() {}
    func push(_ samples: [Float]) {
        pushedTotal += samples.count
    }

    var pushedSamples: Int {
        pushedTotal
    }

    func poll() -> ASREvent? {
        nil
    }

    func finish() -> [ASREvent] {
        []
    }
}

private final class ScriptedCapture: AudioCapturing, @unchecked Sendable {
    var onChunk: ((AudioChunk) -> Void)?
    var onIOError: ((CaptureError) -> Void)?

    func start() async throws {}
    func stop() {}
}
