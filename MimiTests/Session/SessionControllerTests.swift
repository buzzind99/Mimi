import Foundation
@testable import Mimi
import Testing

/// Tests `SessionController` over the injected `makeEngine` / `makeCapture` /
/// `ensurePermission` seams: `begin()` wiring and its failure arms, the
/// capture-chunk → engine-push path, the poll timer's event loop (latency
/// readback, partial → live state, final → sentence pipeline), the
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

    /// Bounded wait proving absence of activity: gives a (buggy) warm-up
    /// spawn a window to run before asserting it did not.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// Pumps the main runloop in short slices for `seconds` total so the
    /// controller's scheduled timers fire, giving the main actor slots
    /// between slices to run the tasks their closures enqueue. For the
    /// absence-of-activity tests, which have no observable success state.
    private func pumpTimers(seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pumpRunLoop(seconds: 0.05)
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Condition-driven timer pump: pumps until `condition` holds or the
    /// timeout expires, so assertions never hinge on a fixed delay outrunning
    /// timer-fire scheduling under load. Returns false on timeout.
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
            ensurePermission: { permissionGranted },
            warmUpEnabled: { true }
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
    func warmUpPreparesOnce() async {
        let sut = makeSUT()

        sut.controller.warmUpIfNeeded(modelURL: warmUpModelURL)
        sut.controller.warmUpIfNeeded(modelURL: warmUpModelURL)
        #expect(
            await pollUntil { sut.log.names == ["factory allowMock=false", "engine.prepare"] }
        )

        #expect(sut.live.partial == "")
        #expect(sut.controller.sessionMetadata == nil)
    }

    /// Pins the production default: inside the unit-test host the warm-up is
    /// gated off (its detached engine construction would race the suites into
    /// a ggml-metal init wedge). The scheduling tests above opt back in via
    /// the `warmUpEnabled` seam.
    @Test("warm-up is suppressed by default in the unit-test host")
    func warmUpDefaultsSuppressedInTestHost() async {
        let log = CallLog()
        let controller = SessionController(
            live: LivePartialState(), latency: LatencyState(), translationQueue: TranslationQueue(),
            makeEngine: { _, allowMock in
                log.record("factory allowMock=\(allowMock)")
                return nil
            }
        )

        controller.warmUpIfNeeded(modelURL: warmUpModelURL)
        controller.warmUpIfNeeded(modelURL: warmUpModelURL)
        await settle()

        #expect(log.names.isEmpty)
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
        await pumpTimers(seconds: 0.3)
        await sut.controller.stop()

        #expect(sut.live.partial == "")
        #expect(sut.controller.sessionMetadata == nil)
    }

    @Test("stop tears down the timers")
    func stopTearsDownTimers() async {
        let sut = makeSUT()

        sut.controller.startTimers()
        await pumpTimers(seconds: 0.3)
        await sut.controller.stop()
        await pumpTimers(seconds: 0.3)

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

        let started = try await sut.controller.begin(modelURL: warmUpModelURL)

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

        _ = try await sut.controller.begin(modelURL: warmUpModelURL)

        let metadata = try #require(sut.controller.sessionMetadata)
        #expect(metadata.model == "mock")
        #expect(metadata.sourceLang == "ja")
        #expect(metadata.targetLang == "en")
        #expect(metadata.chunkMS == 160)
    }

    @Test("begin reports needsModel when no engine resolves")
    func beginWithoutEngineReturnsFalse() async throws {
        let sut = makeSUT(resolveEngine: false)

        let started = try await sut.controller.begin(modelURL: warmUpModelURL)

        #expect(!started)
        #expect(sut.log.names == ["factory allowMock=true"])
        #expect(sut.controller.sessionMetadata == nil)
    }

    @Test("begin throws permissionDenied without Screen Recording access")
    func beginWithoutPermissionThrows() async throws {
        let sut = makeSUT(permissionGranted: false)

        let thrown = await #expect(throws: CaptureError.self) {
            try await sut.controller.begin(modelURL: warmUpModelURL)
        }

        #expect(thrown?.errorDescription == CaptureError.permissionDenied.errorDescription)
        #expect(sut.log.names.isEmpty)
        #expect(sut.controller.sessionMetadata == nil)
    }

    @Test("begin rethrows a capture start failure and skips engine setup")
    func beginCaptureFailureThrows() async throws {
        let sut = makeSUT(captureStartError: CaptureError.streamSetupFailed(captureFailureDetail))

        let thrown = await #expect(throws: CaptureError.self) {
            try await sut.controller.begin(modelURL: warmUpModelURL)
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
        _ = try await sut.controller.begin(modelURL: warmUpModelURL)

        sut.capture.onChunk?(AudioChunk(samples: [0.1, -0.2, 0.3], startSample: 0))

        #expect(sut.engine.allPushedChunks == [[0.1, -0.2, 0.3]])
    }

    @Test("capture chunks update the latency readback on the poll tick")
    func captureChunksUpdateLatency() async throws {
        let sut = makeSUT()
        _ = try await sut.controller.begin(modelURL: warmUpModelURL)

        sut.capture.onChunk?(AudioChunk(samples: [Float](repeating: 0.1, count: 2560), startSample: 0))
        sut.controller.startTimers()
        let surfaced = await pumpTimers(until: sut.latency.seconds == 0.2)

        #expect(surfaced, "the poll tick must surface the latency readback")
        #expect(sut.latency.seconds == 0.2)
    }

    /// Coverage for the DEBUG `logIngressEnergy` body: driven to its 50-chunk
    /// print boundary and beyond is unreachable without real audio; the log
    /// line itself is not asserted.
    @Test("fifty chunks drive the ingress-energy debug path and accumulate latency")
    func fiftyChunksDriveIngressEnergyPath() async throws {
        let sut = makeSUT()
        _ = try await sut.controller.begin(modelURL: warmUpModelURL)

        for index in 0 ..< 50 {
            sut.capture.onChunk?(
                AudioChunk(samples: [Float](repeating: 0.1, count: 2560), startSample: index * 2560)
            )
        }
        sut.controller.startTimers()
        let surfaced = await pumpTimers(until: sut.latency.seconds == 8.0)

        #expect(surfaced, "the poll tick must accumulate the full ingress latency")
        #expect(sut.engine.allPushedChunks.count == 50)
        #expect(sut.controller.sessionMetadata != nil)
        #expect(sut.latency.seconds == 8.0)
    }

    @Test("capture errors surface through onCaptureError")
    func captureErrorsSurface() async throws {
        let sut = makeSUT()
        var messages: [String] = []
        sut.controller.onCaptureError = { messages.append($0) }
        _ = try await sut.controller.begin(modelURL: warmUpModelURL)

        sut.capture.onIOError?(.streamSetupFailed(captureFailureDetail))
        #expect(await pollUntil { !messages.isEmpty }, "the capture error surfaces")

        #expect(messages.first == CaptureError.streamSetupFailed(captureFailureDetail).errorDescription)
    }

    @Test("engine errors surface through onEngineError")
    func engineErrorsSurface() async throws {
        let sut = makeSUT()
        var messages: [String] = []
        sut.controller.onEngineError = { messages.append($0) }
        _ = try await sut.controller.begin(modelURL: warmUpModelURL)

        sut.engine.onEngineError?(engineFailureMessage)
        #expect(await pollUntil { !messages.isEmpty }, "the engine error surfaces")

        #expect(messages == [engineFailureMessage])
    }

    // MARK: - Poll timer event loop

    @Test("the poll timer surfaces a partial to the live state and stop clears it")
    func pollTimerSurfacesPartialAndStopClears() async throws {
        let sut = makeSUT(poll: [.partial(text: pendingPartial)])
        _ = try await sut.controller.begin(modelURL: warmUpModelURL)
        sut.controller.startTimers()
        let surfaced = await pumpTimers(until: sut.live.partial == pendingPartial)
        #expect(surfaced, "the poll timer must surface the scripted partial")
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
        _ = try await sut.controller.begin(modelURL: warmUpModelURL)
        sut.controller.startTimers()
        let emitted = await pumpTimers(until: !sentences.isEmpty)
        await sut.controller.stop()

        #expect(emitted, "the poll timer must route the final into the sentence pipeline")
        #expect(
            sentences == [
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
        _ = try await sut.controller.begin(modelURL: warmUpModelURL)

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

    private let log: CallLog
    private let lock = NSLock()
    private var pollQueue: [ASREvent]
    private let finishQueue: [ASREvent]
    private var pushedChunks: [[Float]] = []
    private var pushedTotal = 0

    init(log: CallLog, poll: [ASREvent] = [], finish: [ASREvent] = []) {
        self.log = log
        pollQueue = poll
        finishQueue = finish
    }

    func prepare() {
        log.record("engine.prepare")
    }

    func openStream() {
        log.record("engine.openStream")
    }

    func push(_ samples: [Float]) {
        lock.withLock {
            pushedChunks.append(samples)
            pushedTotal += samples.count
        }
    }

    var pushedSamples: Int {
        lock.withLock { pushedTotal }
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

private final class ScriptedCapture: AudioCapturing, @unchecked Sendable {
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
