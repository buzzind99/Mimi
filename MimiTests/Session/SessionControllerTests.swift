import Foundation
@testable import Mimi
import Testing

/// Tests `SessionController` over the injected `makeEngine` / `makeCapture` /
/// `ensurePermission` seams: `begin()` wiring and its failure arms, the
/// capture-chunk → engine-push path with the latency readback, the poll
/// timer's event loop (partial → live state, final → sentence pipeline), the
/// engine/capture error callbacks, warm-up scheduling, and stop() teardown
/// ordering.
///
/// Excluded (TCC / ScreenCaptureKit): the real `SystemAudioCapture.start()`
/// SCK stream setup, the real `ensurePermission()` TCC preflight, and the real
/// engine runtime — all are bypassed by injection here, not exercised.
@MainActor
@Suite("SessionController")
struct SessionControllerTests {

    // MARK: - Fixtures

    private let pendingPartial = "認識中"
    private let warmUpModelURL = URL(fileURLWithPath: "/tmp/mimi-warmup.gguf")
    private let captureFailureDetail = "boom"
    private let engineFailureMessage = "decode failed"
    private let fullSentence = "こんにちは。"
    private let flushTailSentence = "おわりです"
    private let oneSecondInSamples = 16000

    // MARK: - Helpers

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Lets scheduled timers fire (poll interval is 0.06 s) and gives the
    /// main actor a slot to run the tasks their closures enqueue.
    private func pumpTimers() async {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func makeSUT(
        permissionGranted: Bool = true,
        resolveEngine: Bool = true,
        poll: [ASREvent] = [],
        finish: [ASREvent] = [],
        captureStartError: (any Error)? = nil
    ) -> SUT {
        let live = LivePartialState()
        let latency = LatencyState()
        let log = CallLog()
        let engine = ScriptedASREngine(log: log, poll: poll, finish: finish)
        let capture = ScriptedCapture(log: log, startError: captureStartError)
        let controller = SessionController(
            live: live, latency: latency, translationQueue: TranslationQueue(),
            makeEngine: { _, allowMock in
                log.record("factory allowMock=\(allowMock)")
                return resolveEngine ? engine : nil
            },
            makeCapture: { capture },
            ensurePermission: { permissionGranted }
        )
        return SUT(
            controller: controller, live: live, latency: latency,
            engine: engine, capture: capture, log: log
        )
    }

    // MARK: - warmUpIfNeeded

    @Test("warm-up with no model URL does nothing")
    func warmUpNoModelURLDoesNothing() {
        let sut = makeSUT()

        sut.controller.warmUpIfNeeded(modelURL: nil)
        sut.controller.warmUpIfNeeded(modelURL: nil)

        #expect(sut.log.names.isEmpty)
        #expect(sut.live.partial == "")
        #expect(sut.controller.sessionMetadata == nil)
    }

    @Test("repeated warm-up calls schedule exactly one background prepare")
    func warmUpPreparesOnce() async throws {
        let sut = makeSUT()

        sut.controller.warmUpIfNeeded(modelURL: warmUpModelURL)
        sut.controller.warmUpIfNeeded(modelURL: warmUpModelURL)
        try await settle()

        #expect(sut.log.names == ["factory allowMock=false", "engine.prepare"])
        #expect(sut.live.partial == "")
        #expect(sut.controller.sessionMetadata == nil)
    }

    // MARK: - stop() without a session

    @Test("stop without a session clears the live partial")
    func stopWithoutSessionClearsLivePartial() async {
        let sut = makeSUT()
        sut.live.partial = pendingPartial

        await sut.controller.stop()

        #expect(sut.live.partial == "")
    }

    @Test("stop without a session keeps the session metadata nil")
    func stopWithoutSessionKeepsMetadataNil() async {
        let sut = makeSUT()

        await sut.controller.stop()

        #expect(sut.controller.sessionMetadata == nil)
    }

    @Test("stop without a session is safe when called twice")
    func stopWithoutSessionTwiceIsSafe() async {
        let sut = makeSUT()
        sut.live.partial = pendingPartial

        await sut.controller.stop()
        await sut.controller.stop()

        #expect(sut.live.partial == "")
    }

    // MARK: - Timer lifecycle

    @Test("timers firing without a session are a no-op")
    func timersWithoutSessionAreNoOp() async {
        let sut = makeSUT()

        sut.controller.startTimers()
        await pumpTimers()
        await sut.controller.stop()

        #expect(sut.live.partial == "")
        #expect(sut.controller.sessionMetadata == nil)
    }

    @Test("stop tears down the timers")
    func stopTearsDownTimers() async {
        let sut = makeSUT()

        sut.controller.startTimers()
        await pumpTimers()
        await sut.controller.stop()
        await pumpTimers()

        #expect(sut.live.partial == "")
        #expect(sut.controller.sessionMetadata == nil)
    }

    // MARK: - begin()

    @Test("begin grants permission, starts capture, then prepares and opens the engine")
    func beginWiresUpSession() async throws {
        let sut = makeSUT()
        sut.live.partial = pendingPartial
        sut.latency.seconds = 0.3
        var sessionBegan = false
        var chosenIsMock: Bool?
        sut.controller.onSessionBegin = { sessionBegan = true }
        sut.controller.onEngineChosen = { isMock, _ in chosenIsMock = isMock }

        let started = try await sut.controller.begin()

        #expect(started)
        #expect(
            sut.log.names ==
                ["factory allowMock=true", "capture.start", "engine.prepare", "engine.openStream"]
        )
        #expect(sessionBegan)
        #expect(chosenIsMock == true)
        #expect(sut.live.partial == "")
        #expect(sut.latency.seconds == 0)
    }

    @Test("begin records mock session metadata")
    func beginCapturesMockMetadata() async throws {
        let sut = makeSUT()

        _ = try await sut.controller.begin()

        let metadata = try #require(sut.controller.sessionMetadata)
        #expect(metadata.model == "mock")
        #expect(metadata.sourceLang == "ja")
        #expect(metadata.targetLang == "en")
        #expect(metadata.chunkMS == 160)
    }

    @Test("begin reports needsModel when no engine resolves")
    func beginWithoutEngineReturnsFalse() async throws {
        let sut = makeSUT(resolveEngine: false)

        let started = try await sut.controller.begin()

        #expect(!started)
        #expect(sut.log.names == ["factory allowMock=true"])
        #expect(sut.controller.sessionMetadata == nil)
    }

    @Test("begin throws permissionDenied without Screen Recording access")
    func beginWithoutPermissionThrows() async throws {
        let sut = makeSUT(permissionGranted: false)

        let thrown = await #expect(throws: CaptureError.self) {
            try await sut.controller.begin()
        }

        #expect(thrown?.errorDescription == CaptureError.permissionDenied.errorDescription)
        #expect(sut.log.names.isEmpty)
        #expect(sut.controller.sessionMetadata == nil)
    }

    @Test("begin rethrows a capture start failure and skips engine setup")
    func beginCaptureFailureThrows() async throws {
        let sut = makeSUT(captureStartError: CaptureError.streamSetupFailed(captureFailureDetail))

        let thrown = await #expect(throws: CaptureError.self) {
            try await sut.controller.begin()
        }

        #expect(
            thrown?.errorDescription == CaptureError.streamSetupFailed(captureFailureDetail).errorDescription
        )
        #expect(sut.log.names == ["factory allowMock=true", "capture.start"])
        #expect(sut.controller.sessionMetadata == nil)
    }

    // MARK: - Capture chunk path

    @Test("capture chunks are pushed into the engine")
    func captureChunksPushIntoEngine() async throws {
        let sut = makeSUT()
        _ = try await sut.controller.begin()

        sut.capture.onChunk?(AudioChunk(samples: [0.1, -0.2, 0.3], startSample: 0))

        #expect(sut.engine.allPushedChunks == [[0.1, -0.2, 0.3]])
    }

    @Test("capture chunks update the latency readback")
    func captureChunksUpdateLatency() async throws {
        let sut = makeSUT()
        _ = try await sut.controller.begin()

        sut.capture.onChunk?(AudioChunk(samples: [Float](repeating: 0.1, count: 2560), startSample: 0))
        try await settle()

        #expect(sut.latency.seconds == 0.2)
    }

    @Test("capture errors surface through onCaptureError")
    func captureErrorsSurface() async throws {
        let sut = makeSUT()
        var messages: [String] = []
        sut.controller.onCaptureError = { messages.append($0) }
        _ = try await sut.controller.begin()

        sut.capture.onIOError?(.streamSetupFailed(captureFailureDetail))
        try await settle()

        #expect(messages.first == CaptureError.streamSetupFailed(captureFailureDetail).errorDescription)
    }

    @Test("engine errors surface through onEngineError")
    func engineErrorsSurface() async throws {
        let sut = makeSUT()
        var messages: [String] = []
        sut.controller.onEngineError = { messages.append($0) }
        _ = try await sut.controller.begin()

        sut.engine.onEngineError?(engineFailureMessage)
        try await settle()

        #expect(messages == [engineFailureMessage])
    }

    // MARK: - Poll timer event loop

    @Test("the poll timer surfaces a partial to the live state and stop clears it")
    func pollTimerSurfacesPartialAndStopClears() async throws {
        let sut = makeSUT(poll: [.partial(text: pendingPartial)])
        _ = try await sut.controller.begin()
        sut.controller.startTimers()
        await pumpTimers()
        let surfacedPartial = sut.live.partial

        await sut.controller.stop()

        #expect(surfacedPartial == pendingPartial)
        #expect(sut.live.partial == "")
    }

    @Test("the poll timer routes a final into the sentence pipeline")
    func pollTimerEmitsSentence() async throws {
        let sut = makeSUT(poll: [
            .final(
                text: fullSentence, startSample: 0,
                endSample: oneSecondInSamples, lang: "ja"
            )
        ])
        var sentences: [Sentence] = []
        sut.controller.onSentence = { sentences.append($0) }
        _ = try await sut.controller.begin()
        sut.controller.startTimers()
        await pumpTimers()
        let emitted = sentences
        await sut.controller.stop()

        #expect(
            emitted == [
                Sentence(index: 0, startS: 0.0, endS: 1.0, lang: "ja", text: fullSentence)
            ]
        )
    }

    // MARK: - stop() teardown ordering

    @Test("stop stops capture, drains the engine, then flushes the buffer")
    func stopOrderingAndFlush() async throws {
        let sut = makeSUT(finish: [
            .final(
                text: flushTailSentence, startSample: 0,
                endSample: oneSecondInSamples, lang: "ja"
            )
        ])
        var sentences: [Sentence] = []
        sut.controller.onSentence = { sentences.append($0) }
        _ = try await sut.controller.begin()

        await sut.controller.stop()

        #expect(
            sut.log.names == [
                "factory allowMock=true", "capture.start", "engine.prepare",
                "engine.openStream", "capture.stop", "engine.finish"
            ]
        )
        #expect(
            sentences == [
                Sentence(index: 0, startS: 0.0, endS: 1.0, lang: "ja", text: flushTailSentence)
            ]
        )
        #expect(sut.live.partial == "")
    }
}

private struct SUT {
    let controller: SessionController
    let live: LivePartialState
    let latency: LatencyState
    let engine: ScriptedASREngine
    let capture: ScriptedCapture
    let log: CallLog
}

private final class CallLog {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ name: String) {
        lock.withLock { entries.append(name) }
    }

    var names: [String] {
        lock.withLock { entries }
    }
}

private final class ScriptedASREngine: ASREngine {
    let isMock = true
    var onEngineError: ((String) -> Void)?
    var processedSamples = 0

    private let log: CallLog
    private let lock = NSLock()
    private var pollQueue: [ASREvent]
    private let finishQueue: [ASREvent]
    private var pushedChunks: [[Float]] = []

    init(log: CallLog, poll: [ASREvent] = [], finish: [ASREvent] = []) {
        self.log = log
        pollQueue = poll
        finishQueue = finish
    }

    func prepare() throws {
        log.record("engine.prepare")
    }

    func openStream() throws {
        log.record("engine.openStream")
    }

    func push(_ samples: [Float]) {
        lock.withLock { pushedChunks.append(samples) }
    }

    func poll() -> ASREvent? {
        log.record("engine.poll")
        lock.lock()
        defer { lock.unlock() }
        guard !pollQueue.isEmpty else { return nil }
        return pollQueue.removeFirst()
    }

    func finish() -> [ASREvent] {
        log.record("engine.finish")
        return finishQueue
    }

    var allPushedChunks: [[Float]] {
        lock.withLock { pushedChunks }
    }
}

private final class ScriptedCapture: AudioCapturing {
    var onChunk: ((AudioChunk) -> Void)?
    var onIOError: ((CaptureError) -> Void)?

    private let log: CallLog
    private let startError: (any Error)?

    init(log: CallLog, startError: (any Error)? = nil) {
        self.log = log
        self.startError = startError
    }

    func start() async throws {
        log.record("capture.start")
        if let startError {
            throw startError
        }
    }

    func stop() {
        log.record("capture.stop")
    }
}
