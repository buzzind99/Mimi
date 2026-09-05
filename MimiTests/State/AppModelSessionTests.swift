import Foundation
@testable import Mimi
import Testing

/// Tests `AppModel.start()`'s full flow — dictionary gate (a dictionary is
/// installed on this machine, so it passes through) → `SessionController.begin()`
/// → running, with translation activation — over an injected
/// `makeSessionController` factory wiring scripted engine/capture doubles, and
/// `stop()`'s interaction with an in-flight start. The factory and capture are
/// also reachable by `AppModel`'s own detached warm-up, so log assertions use
/// ordered-subsequence checks rather than exact equality.
///
/// Excluded: the `.needsModel` → dictionary-gate throw inside `start()` is
/// unreachable through the default `ensureDictionaryReady` on a machine with
/// a dictionary (covered via injected closures in `AppModelDictionaryTests`);
/// `start()`'s catch → `.failed` is exercised through the capture-start
/// throw, which lands in the same catch. The real factories (TCC preflight,
/// SCK stream) stay production-only.
@MainActor
@Suite("AppModel session flow", .enabled(if: DictionaryStore.resolve() != nil))
struct AppModelSessionTests {

    // MARK: - Fixtures

    /// Thread-safe ordered call log (main actor + detached warm-up interleave).
    private final class FlowLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func record(_ name: String) {
            lock.withLock { entries.append(name) }
        }

        var names: [String] {
            lock.withLock { entries }
        }

        func contains(inOrder needle: [String]) -> Bool {
            var index = 0
            for entry in names where index < needle.count {
                if entry == needle[index] {
                    index += 1
                }
            }
            return index == needle.count
        }
    }

    private final class ScriptedASREngine: ASREngine, @unchecked Sendable {
        let isMock = true
        var onEngineError: ((String) -> Void)?
        var processedSamples = 0
        var pushedSamples = 0

        private let log: FlowLog
        private let pollScript: [ASREvent]
        private var pollIndex = 0

        init(log: FlowLog, poll: [ASREvent] = []) {
            self.log = log
            pollScript = poll
        }

        func prepare() {
            log.record("engine.prepare")
        }

        func openStream() {
            log.record("engine.openStream")
        }

        func push(_ samples: [Float]) {}

        func poll() -> ASREvent? {
            guard pollIndex < pollScript.count else { return nil }
            defer { pollIndex += 1 }
            return pollScript[pollIndex]
        }

        func finish() -> [ASREvent] {
            []
        }
    }

    private final class ScriptedCapture: AudioCapturing, @unchecked Sendable {
        var onChunk: ((AudioChunk) -> Void)?
        var onIOError: ((CaptureError) -> Void)?

        private let log: FlowLog
        private let startError: (any Error)?
        private let restartStartError: (any Error)?
        private let startGate: StartGate?
        private let lock = NSLock()
        private var starts = 0

        init(
            log: FlowLog, startError: (any Error)? = nil,
            restartStartError: (any Error)? = nil, startGate: StartGate? = nil
        ) {
            self.log = log
            self.startError = startError
            self.restartStartError = restartStartError
            self.startGate = startGate
        }

        func start() async throws {
            // The first start is `begin()`'s; later starts are restarts.
            let attempt = lock.withLock { starts += 1; return starts }
            log.record("capture.start")
            // Suspend (never block the main actor thread) until the test
            // opens the gate.
            if let startGate {
                await startGate.wait()
            }
            if attempt > 1, let restartStartError {
                throw restartStartError
            }
            if let startError {
                throw startError
            }
        }

        func stop() {
            log.record("capture.stop")
        }
    }

    /// One-shot suspension gate for `capture.start`.
    private final class StartGate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func wait() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    _ = self.semaphore.wait(timeout: .now() + 10)
                    continuation.resume()
                }
            }
        }

        func open() {
            semaphore.signal()
        }
    }

    private struct ScriptedStartError: LocalizedError {
        var errorDescription: String? {
            "boom"
        }
    }

    private struct SUT {
        let model: AppModel
        let controller: SessionController
        let engine: ScriptedASREngine
        let capture: ScriptedCapture
        let log: FlowLog
    }

    private func makeSUT(
        resolveEngine: Bool = true,
        poll: [ASREvent] = [],
        captureStartError: (any Error)? = nil,
        restartStartError: (any Error)? = nil,
        startGate: StartGate? = nil
    ) async -> SUT {
        let log = FlowLog()
        let engine = ScriptedASREngine(log: log, poll: poll)
        let capture = ScriptedCapture(
            log: log, startError: captureStartError,
            restartStartError: restartStartError, startGate: startGate
        )
        let model = AppModel(
            makeSessionController: { live, latency, _, translationQueue in
                SessionController(
                    live: live, latency: latency, translationQueue: translationQueue,
                    makeEngine: { _, allowMock in
                        log.record("factory allowMock=\(allowMock)")
                        return resolveEngine ? engine : nil
                    },
                    makeCapture: { capture },
                    ensurePermission: { true },
                    // Keep the detached-warm-up interleave (fake engine, safe)
                    // that the ordered-subsequence log assertions account for.
                    warmUpEnabled: { true }
                )
            },
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelSession"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelSession"),
            // Stub the launch check: the real locator hashes the dev GGUF and
            // the resolved URL feeds the warm-up. The scripted URL below
            // drives the same path over the injected doubles.
            initialModelResolve: { _ in nil },
            retireWarmEngine: { log.record("engine.retire") }
        )
        // Quiesce the launch-time model check, then force an idle start with
        // a synthetic model URL (model discovery is async now).
        await model.initialModelCheck?.value
        await model.refreshModelAvailability(resolve: { _ in URL(fileURLWithPath: "/tmp/model.gguf") })
        return SUT(
            model: model, controller: model.sessionController,
            engine: engine, capture: capture, log: log
        )
    }

    // MARK: - start() happy path

    @Test("start brings the session up to running, surfaces partials, and wires translation")
    func startRunsHappyPath() async {
        let sut = await makeSUT(poll: [.partial(text: "ライブ")])

        sut.model.start()

        #expect(sut.model.phase == .starting)
        #expect(await pollUntil { sut.model.phase == .running }, "start brings the session up to running")
        #expect(sut.model.translationConfig != nil)
        #expect(sut.controller.sessionMetadata != nil)
        #expect(await pollUntil { sut.model.live.partial == "ライブ" }, "the scripted partial surfaces")
        #expect(sut.model.live.partial == "ライブ")

        sut.model.stop()
        #expect(sut.model.phase == .stopping)
        #expect(await pollUntil { sut.model.phase == .idle }, "stop winds down to idle")
        #expect(sut.model.live.partial == "")
        #expect(sut.model.translationStatus == .idle)
        #expect(
            sut.log.contains(
                inOrder: [
                    "factory allowMock=true", "capture.start",
                    "engine.prepare", "engine.openStream", "capture.stop"
                ]
            )
        )
    }

    // MARK: - start() failure arms

    @Test("start lands in needsModel when no engine resolves")
    func startWithNoEngineMarksNeedsModel() async {
        let sut = await makeSUT(resolveEngine: false)

        sut.model.start()

        #expect(await pollUntil { sut.model.phase == .needsModel }, "start lands in needsModel")
        #expect(sut.model.translationConfig == nil)
        #expect(sut.controller.sessionMetadata == nil)
        #expect(!sut.log.names.contains("capture.start"))
    }

    @Test("a capture-start failure fails the start visibly")
    func captureStartFailureFailsStart() async {
        let sut = await makeSUT(captureStartError: ScriptedStartError())

        sut.model.start()

        #expect(await pollUntil { sut.model.phase == .failed("boom") }, "the capture failure fails the start")
        #expect(sut.log.names.contains("capture.start"))
        #expect(sut.controller.sessionMetadata == nil)
        #expect(sut.model.translationConfig == nil)
        // The failure surfaces as the session.failed card: no
        // action, dismissed by the next Start.
        let toast = sut.model.toasts.toasts.first { $0.key == ToastKey.sessionFailed }
        #expect(toast?.style == .redPersistent)
        #expect(toast?.body == "boom")
        #expect(toast?.action == nil)
    }

    /// The failure card is "cleared on next Start": the dismissal happens
    /// synchronously at start entry, before the second attempt's own outcome.
    @Test("a previous session's failure card is cleared by the next Start")
    func startClearsPreviousSessionFailedToast() async {
        let sut = await makeSUT(captureStartError: ScriptedStartError())
        sut.model.start()
        #expect(await pollUntil { sut.model.phase == .failed("boom") }, "the capture failure fails the start")
        #expect(!sut.model.toasts.toasts.isEmpty, "the failure card is up")

        sut.model.start()

        #expect(sut.model.toasts.toasts.isEmpty, "the stale failure card was dismissed on entry")
    }

    @Test("a failed session restarts on Start")
    func failedSessionRestartsOnStart() async {
        let sut = await makeSUT(captureStartError: ScriptedStartError())
        sut.model.start()
        #expect(await pollUntil { sut.model.phase == .failed("boom") }, "the capture failure fails the start")

        sut.model.start()

        #expect(await pollUntil { sut.model.phase == .failed("boom") }, "the second attempt fails again (startError persists)")
        #expect(
            sut.log.names.filter { $0 == "capture.start" }.count == 2,
            "the failed session was allowed to attempt a restart"
        )
    }

    // MARK: - stop() during start

    @Test("stop while starting tears down and winds down to idle")
    func stopWhileStartingTearsDown() async {
        let gate = StartGate()
        let sut = await makeSUT(startGate: gate)

        sut.model.start()
        #expect(await pollUntil { sut.log.names.contains("capture.start") }, "capture starts before the stop")
        #expect(sut.model.phase == .starting)

        sut.model.stop()
        #expect(sut.model.phase == .stopping)

        gate.open()
        // Teardown runs through a detached engine finish and the queue drain
        // (5 s bound) — give it the same headroom.
        #expect(await pollUntil(timeout: 5) { sut.model.phase == .idle }, "the stop winds down to idle")

        #expect(sut.model.live.partial == "")
        // Teardown must run (and beat the resumed begin, whose tail is a
        // no-op against a stopped session) in both interleavings.
        #expect(sut.log.contains(inOrder: ["capture.start", "capture.stop"]))
    }

    // MARK: - capture.lost + restartCapture

    /// The capture error path: a mid-session stream death parks the model
    /// on `.sourceLost` with the red capture.lost card; the card's Restart
    /// action rebuilds only the capture (engine untouched, entries and clock
    /// intact) and returns to running.
    @Test("a mid-session capture error posts capture.lost and restart recovers")
    func captureErrorPostsToastAndRestartRecovers() async {
        let sut = await makeSUT(poll: [
            .final(text: "おわり。", startSample: 0, endSample: 16000, lang: "ja")
        ])
        sut.model.start()
        #expect(await pollUntil { sut.model.phase == .running }, "start brings the session up to running")
        #expect(await pollUntil { sut.model.entries.count == 1 }, "the scripted final lands in the transcript")

        sut.capture.onIOError?(.streamSetupFailed("stream died"))
        #expect(await pollUntil { sut.model.phase == .sourceLost }, "the capture death parks the model on source lost")

        let toast = sut.model.toasts.toasts.first { $0.key == ToastKey.captureLost }
        #expect(toast?.style == .redPersistent)
        #expect(toast?.body == CaptureError.streamSetupFailed("stream died").errorDescription)
        #expect(toast?.action?.label == "Restart capture")

        sut.model.restartCapture()

        #expect(await pollUntil { sut.model.phase == .running }, "the restart brings the session back up")
        #expect(sut.model.toasts.toasts.isEmpty, "the capture.lost card is dismissed on recovery")
        #expect(sut.model.entries.count == 1, "entries survive the restart")
        #expect(
            sut.log.contains(inOrder: ["capture.start", "capture.stop", "capture.start"]),
            "only the capture stream was rebuilt"
        )
        #expect(
            sut.log.names.filter { $0 == "engine.openStream" }.count == 1,
            "the engine was not reloaded (warm-up's prepare aside, no new stream opened)"
        )
    }

    @Test("restartCapture is refused while the session is live")
    func restartRefusedWhileRunning() async {
        let sut = await makeSUT()
        sut.model.start()
        #expect(await pollUntil { sut.model.phase == .running }, "start brings the session up to running")

        sut.model.restartCapture()

        #expect(sut.model.phase == .running)
        #expect(!sut.log.names.contains("capture.stop"), "nothing was torn down")
    }

    @Test("a failed restart keeps the source lost with an updated toast")
    func failedRestartKeepsSourceLost() async {
        let sut = await makeSUT(restartStartError: ScriptedStartError())
        sut.model.start()
        #expect(await pollUntil { sut.model.phase == .running }, "start brings the session up to running")

        sut.controller.onCaptureError?("stream died")
        #expect(await pollUntil { sut.model.phase == .sourceLost }, "the capture death parks the model on source lost")

        sut.model.restartCapture()

        #expect(await pollUntil { sut.model.phase == .sourceLost }, "the failed restart returns to source lost")
        let toast = sut.model.toasts.toasts.first { $0.key == ToastKey.captureLost }
        #expect(toast?.body == "Restart failed: boom", "the card carries the restart failure")
        #expect(toast?.action?.label == "Restart capture", "the fix action stays actionable")
    }

    // MARK: - quit-time shutdown

    @Test("shutdownForTermination during a running session stops it, then retires the warm engine")
    func shutdownDuringRunningSessionStopsThenRetires() async {
        let sut = await makeSUT()

        sut.model.start()
        #expect(await pollUntil { sut.model.phase == .running }, "start brings the session up to running")

        await sut.model.shutdownForTermination()

        #expect(sut.model.phase == .idle)
        #expect(
            sut.log.contains(inOrder: ["capture.stop", "engine.retire"]),
            "the engine is only released after the session teardown drained"
        )
    }

    @Test("shutdownForTermination while idle still retires the warm engine")
    func shutdownWhileIdleStillRetires() async {
        let sut = await makeSUT()

        await sut.model.shutdownForTermination()

        #expect(sut.model.phase == .idle)
        #expect(sut.log.names.contains("engine.retire"))
    }

    @Test("shutdownForTermination after a manual stop awaits it and retires once")
    func shutdownAfterManualStopRetiresOnce() async {
        let sut = await makeSUT(poll: [.partial(text: "ライブ")])

        sut.model.start()
        #expect(await pollUntil { sut.model.phase == .running }, "start brings the session up to running")
        sut.model.stop()
        #expect(await pollUntil { sut.model.phase == .idle }, "the manual stop winds down to idle")

        await sut.model.shutdownForTermination()

        #expect(sut.log.names.filter { $0 == "engine.retire" } == ["engine.retire"])
    }

    @Test("start is refused once termination teardown has begun")
    func startRefusedAfterTerminationBegins() async {
        let sut = await makeSUT()

        await sut.model.shutdownForTermination()
        sut.model.start()

        #expect(sut.model.phase == .idle, "a terminating model never begins a new session")
        #expect(!sut.log.names.contains("capture.start"), "no capture came up after teardown")
    }
}
