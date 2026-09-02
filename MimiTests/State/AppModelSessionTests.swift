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

        func prepare() throws {
            log.record("engine.prepare")
        }

        func openStream() throws {
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

    private final class ScriptedCapture: AudioCapturing {
        var onChunk: ((AudioChunk) -> Void)?
        var onIOError: ((CaptureError) -> Void)?

        private let log: FlowLog
        private let startError: (any Error)?
        private let startGate: StartGate?

        init(log: FlowLog, startError: (any Error)? = nil, startGate: StartGate? = nil) {
            self.log = log
            self.startError = startError
            self.startGate = startGate
        }

        func start() async throws {
            log.record("capture.start")
            // Suspend (never block the main actor thread) until the test
            // opens the gate.
            if let startGate {
                await startGate.wait()
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
        startGate: StartGate? = nil
    ) async -> SUT {
        let log = FlowLog()
        let engine = ScriptedASREngine(log: log, poll: poll)
        let capture = ScriptedCapture(log: log, startError: captureStartError, startGate: startGate)
        let model = AppModel { live, latency, translationQueue in
            SessionController(
                live: live, latency: latency, translationQueue: translationQueue,
                makeEngine: { _, allowMock in
                    log.record("factory allowMock=\(allowMock)")
                    return resolveEngine ? engine : nil
                },
                makeCapture: { capture },
                ensurePermission: { true }
            )
        }
        // Quiesce the launch-time model check, then force an idle start with
        // a synthetic model URL (model discovery is async now).
        await model.initialModelCheck?.value
        await model.refreshModelAvailability(resolve: { URL(fileURLWithPath: "/tmp/model.gguf") })
        return SUT(
            model: model, controller: model.sessionController,
            engine: engine, capture: capture, log: log
        )
    }

    /// Lets spawned tasks and teardown finish before assertions.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// Pumps the main runloop so scheduled timers fire (poll interval is
    /// 0.06 s) while `condition` is unmet.
    private func pumpUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - start() happy path

    @Test("start brings the session up to running, surfaces partials, and wires translation")
    func startRunsHappyPath() async {
        let sut = await makeSUT(poll: [.partial(text: "ライブ")])

        sut.model.start()

        #expect(sut.model.phase == .starting)
        await pumpUntil { sut.model.phase == .running }
        #expect(sut.model.phase == .running)
        #expect(sut.model.translationConfig != nil)
        #expect(sut.model.errorMessage == nil)
        #expect(sut.controller.sessionMetadata != nil)
        await pumpUntil { sut.model.live.partial == "ライブ" }
        #expect(sut.model.live.partial == "ライブ")

        sut.model.stop()
        #expect(sut.model.phase == .stopping)
        await settle()
        #expect(sut.model.phase == .idle)
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

        await pumpUntil { sut.model.phase == .needsModel }
        #expect(sut.model.phase == .needsModel)
        #expect(sut.model.translationConfig == nil)
        #expect(sut.controller.sessionMetadata == nil)
        #expect(!sut.log.names.contains("capture.start"))
    }

    @Test("a capture-start failure fails the start visibly")
    func captureStartFailureFailsStart() async {
        let sut = await makeSUT(captureStartError: ScriptedStartError())

        sut.model.start()

        await pumpUntil { sut.model.phase == .failed("boom") }
        #expect(sut.model.phase == .failed("boom"))
        #expect(sut.log.names.contains("capture.start"))
        #expect(sut.controller.sessionMetadata == nil)
        #expect(sut.model.translationConfig == nil)
    }

    // MARK: - stop() during start

    @Test("stop while starting tears down and winds down to idle")
    func stopWhileStartingTearsDown() async {
        let gate = StartGate()
        let sut = await makeSUT(startGate: gate)

        sut.model.start()
        await pumpUntil { sut.log.names.contains("capture.start") }
        #expect(sut.model.phase == .starting)

        sut.model.stop()
        #expect(sut.model.phase == .stopping)

        gate.open()
        await settle()

        #expect(sut.model.phase == .idle)
        #expect(sut.model.live.partial == "")
        // Teardown must run (and beat the resumed begin, whose tail is a
        // no-op against a stopped session) in both interleavings.
        #expect(sut.log.contains(inOrder: ["capture.start", "capture.stop"]))
    }
}
