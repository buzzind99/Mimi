@testable import Mimi
import XCTest

/// Tests `SessionController`'s testable surface: warm-up scheduling guards,
/// no-session teardown, and timer lifecycle. `begin()` is excluded (TCC
/// prompt + live capture), so engine-dependent paths (`pollASR`'s loop,
/// `handleASREvent`, `handleCaptureChunk`) have no reachable state — the
/// engine is private and installed only by `begin()` (documented exclusion).
@MainActor
final class SessionControllerTests: XCTestCase {

    // MARK: - Fixtures

    private let pendingPartial = "認識中"
    /// Nonexistent path: the detached warm-up either gets no engine from the
    /// factory or fails `prepare` with modelNotFound (swallowed by `try?`).
    private let missingModelURL = URL(fileURLWithPath: "/tmp/mimi-missing-model.gguf")

    // MARK: - Helpers

    private func makeSUT() -> (controller: SessionController, live: LivePartialState) {
        let live = LivePartialState()
        let controller = SessionController(
            live: live, latency: LatencyState(), translationQueue: TranslationQueue()
        )
        return (controller, live)
    }

    /// Lets the detached warm-up task finish before the test ends.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Lets scheduled timers fire (poll interval is 0.06 s) and gives the
    /// main actor a slot to run the tasks their closures enqueue.
    private func pumpTimers() async {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - warmUpIfNeeded

    func test_warmUpIfNeeded_whenModelURLIsNil_shouldBeNoOp() {
        let (controller, live) = makeSUT()

        controller.warmUpIfNeeded(modelURL: nil)
        controller.warmUpIfNeeded(modelURL: nil)

        XCTAssertEqual(live.partial, "")
        XCTAssertNil(controller.sessionMetadata)
    }

    func test_warmUpIfNeeded_whenModelURLGiven_whenCalledTwice_shouldStaySafe() async throws {
        let (controller, live) = makeSUT()

        controller.warmUpIfNeeded(modelURL: missingModelURL)
        controller.warmUpIfNeeded(modelURL: missingModelURL)

        try await settle()

        XCTAssertEqual(live.partial, "")
        XCTAssertNil(controller.sessionMetadata)
    }

    // MARK: - stop() without a session

    func test_stop_whenNoSession_shouldClearLivePartial() async {
        let (controller, live) = makeSUT()
        live.partial = pendingPartial

        await controller.stop()

        XCTAssertEqual(live.partial, "")
    }

    func test_stop_whenNoSession_shouldKeepSessionMetadataNil() async {
        let (controller, _) = makeSUT()

        await controller.stop()

        XCTAssertNil(controller.sessionMetadata)
    }

    func test_stop_whenNoSession_whenCalledTwice_shouldBeSafe() async {
        let (controller, live) = makeSUT()
        live.partial = pendingPartial

        await controller.stop()
        await controller.stop()

        XCTAssertEqual(live.partial, "")
    }

    // MARK: - Timer lifecycle

    func test_startTimers_whenTimersFireWithoutSession_shouldBeNoOp() async {
        let (controller, live) = makeSUT()

        controller.startTimers()
        await pumpTimers()

        XCTAssertEqual(live.partial, "")
        XCTAssertNil(controller.sessionMetadata)

        await controller.stop()
    }

    func test_stop_afterStartTimers_shouldTearDownTimers() async {
        let (controller, live) = makeSUT()
        controller.startTimers()
        await pumpTimers()

        await controller.stop()
        await pumpTimers()

        XCTAssertEqual(live.partial, "")
        XCTAssertNil(controller.sessionMetadata)
    }
}
