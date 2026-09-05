import Foundation
@testable import Mimi
import Testing

/// Tests `SessionController.restartCapture()`: the `capture.lost` toast's fix
/// path rebuilds only the capture stream — the engine (with its loaded
/// model), timers, sentence buffer, and metadata are untouched, the factory
/// does not re-fire, and `onSessionBegin` does not re-fire (no transcript
/// reset). A no-op without a session; a rebuild failure rethrows after the
/// dead stream was fenced.
@MainActor
@Suite("SessionController restartCapture")
struct SessionControllerRestartTests {

    // MARK: - Fixtures

    private let warmUpModelURL = URL(fileURLWithPath: "/tmp/mimi-warmup.gguf")
    private let sessionModelID = "test-model-GGUF"
    private let captureFailureDetail = "boom"

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func record(_ name: String) {
            lock.withLock { entries.append(name) }
        }

        var names: [String] {
            lock.withLock { entries }
        }
    }

    private final class ScriptedASREngine: ASREngine, @unchecked Sendable {
        let isMock = true
        var onEngineError: ((String) -> Void)?
        var processedSamples = 0
        var pushedSamples = 0

        private let log: CallLog
        private let lock = NSLock()
        private var pushedChunks: [[Float]] = []

        init(log: CallLog) {
            self.log = log
        }

        func prepare() {
            log.record("engine.prepare")
        }

        func openStream() {
            log.record("engine.openStream")
        }

        func push(_ samples: [Float]) {
            lock.withLock { pushedChunks.append(samples) }
        }

        func poll() -> ASREvent? {
            nil
        }

        func finish() -> [ASREvent] {
            log.record("engine.finish")
            return []
        }

        var allPushedChunks: [[Float]] {
            lock.withLock { pushedChunks }
        }
    }

    private final class ScriptedCapture: AudioCapturing, @unchecked Sendable {
        var onChunk: ((AudioChunk) -> Void)?
        var onIOError: ((CaptureError) -> Void)?

        private let log: CallLog

        init(log: CallLog) {
            self.log = log
        }

        func start() async throws {
            log.record("capture.start")
        }

        func stop() {
            log.record("capture.stop")
        }
    }

    /// A capture that starts fine once, then fails (the source died and will
    /// not come back without a fix).
    private final class FlakyCapture: AudioCapturing, @unchecked Sendable {
        var onChunk: ((AudioChunk) -> Void)?
        var onIOError: ((CaptureError) -> Void)?

        private let log: CallLog
        private let lock = NSLock()
        private var starts = 0

        init(log: CallLog) {
            self.log = log
        }

        func start() async throws {
            let attempt = lock.withLock { starts += 1; return starts }
            log.record("capture.start#\(attempt)")
            if attempt > 1 {
                throw CaptureError.streamSetupFailed("boom")
            }
        }

        func stop() {
            log.record("capture.stop")
        }
    }

    private struct SUT {
        let controller: SessionController
        let engine: ScriptedASREngine
        let capture: ScriptedCapture
        let log: CallLog
    }

    private func makeSUT() -> SUT {
        let log = CallLog()
        let engine = ScriptedASREngine(log: log)
        let capture = ScriptedCapture(log: log)
        let controller = SessionController(
            live: LivePartialState(), latency: LatencyState(), translationQueue: TranslationQueue(),
            makeEngine: { _, allowMock in
                log.record("factory allowMock=\(allowMock)")
                return engine
            },
            makeCapture: { capture },
            ensurePermission: { true },
            warmUpEnabled: { false }
        )
        return SUT(controller: controller, engine: engine, capture: capture, log: log)
    }

    // MARK: - Tests

    /// Chunks from the rebuilt stream flow into the same engine.
    @Test("restartCapture rebuilds the capture stream and reuses the engine")
    func restartCaptureRebuildsCaptureReusingEngine() async throws {
        let sut = makeSUT()
        var sessionBegins = 0
        sut.controller.onSessionBegin = { sessionBegins += 1 }
        _ = try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)
        sut.controller.startTimers()
        #expect(sessionBegins == 1)

        try await sut.controller.restartCapture()

        #expect(
            sut.log.names == [
                "factory allowMock=true", "capture.start", "engine.prepare",
                "engine.openStream", "capture.stop", "capture.start"
            ],
            "only the capture is torn down and rebuilt; no factory or engine re-fire"
        )
        #expect(sessionBegins == 1, "onSessionBegin does not re-fire")
        #expect(sut.controller.sessionMetadata != nil, "session metadata is untouched")

        sut.capture.onChunk?(AudioChunk(samples: [0.4, -0.4], startSample: 0))
        #expect(sut.engine.allPushedChunks.count == 1)
    }

    @Test("restartCapture without a session is a no-op")
    func restartCaptureWithoutSessionIsNoOp() async throws {
        let sut = makeSUT()

        try await sut.controller.restartCapture()

        #expect(sut.log.names.isEmpty)
        #expect(sut.controller.sessionMetadata == nil)
    }

    @Test("restartCapture rethrows a capture start failure after fencing the dead stream")
    func restartCaptureFailureThrows() async throws {
        let log = CallLog()
        let capture = FlakyCapture(log: log)
        let controller = SessionController(
            live: LivePartialState(), latency: LatencyState(), translationQueue: TranslationQueue(),
            makeEngine: { _, allowMock in
                log.record("factory allowMock=\(allowMock)")
                return ScriptedASREngine(log: log)
            },
            makeCapture: { capture },
            ensurePermission: { true },
            warmUpEnabled: { false }
        )
        _ = try await controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)

        let thrown = await #expect(throws: CaptureError.self) {
            try await controller.restartCapture()
        }

        #expect(
            thrown?.errorDescription == CaptureError.streamSetupFailed(captureFailureDetail).errorDescription
        )
        #expect(
            log.names == [
                "factory allowMock=true", "capture.start#1", "engine.prepare",
                "engine.openStream", "capture.stop", "capture.start#2"
            ],
            "the dead stream was fenced before the failed rebuild"
        )
    }
}
