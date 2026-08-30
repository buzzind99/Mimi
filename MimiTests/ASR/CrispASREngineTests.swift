@testable import Mimi
import XCTest

/// Tests the `CrispASREngine` paths reachable without a loaded GGUF model or
/// a Metal pipeline: the init bind-failure throw (assertable only when the
/// dylib is absent), `prepare`'s missing-model guard, `openStream`'s state
/// reset, `push`'s session guard, `poll` on an empty inbox, `close`
/// idempotency, and `finish`'s sessionless drain (no in-flight jobs →
/// immediate empty drain).
final class CrispASREngineTests: XCTestCase {

    // MARK: - Fixtures

    /// Exists only to prove the model-file guard fires before any C call.
    private static let missingModelURL = URL(fileURLWithPath: "/tmp/mimi-crisp-missing.gguf")

    private var engine: CrispASREngine?

    override func setUp() {
        super.setUp()
        // Succeeds iff the dylib binds (init never touches the model file).
        engine = try? CrispASREngine(modelPath: Self.missingModelURL)
    }

    private func requireEngine() throws -> CrispASREngine {
        guard let engine else {
            throw XCTSkip("native runtime is not available in this environment")
        }
        return engine
    }

    // MARK: - init / binding

    func test_init_whenDylibUnavailable_shouldThrowRuntimeNotFound() throws {
        try XCTSkipIf(engine != nil, "native runtime is available in this environment")

        XCTAssertThrowsError(try CrispASREngine(modelPath: Self.missingModelURL)) { error in
            guard case let ASREngineError.runtimeNotFound(detail) = error else {
                return XCTFail("expected .runtimeNotFound, got \(error)")
            }
            XCTAssertFalse(detail.isEmpty)
        }
    }

    func test_isMock_shouldBeFalse() throws {
        let engine = try requireEngine()

        XCTAssertEqual(engine.isMock, false)
    }

    // MARK: - prepare (missing model)

    func test_prepare_whenModelMissing_shouldThrowModelNotFoundWithPath() throws {
        let engine = try requireEngine()

        XCTAssertThrowsError(try engine.prepare()) { error in
            guard case let ASREngineError.modelNotFound(path) = error else {
                return XCTFail("expected .modelNotFound, got \(error)")
            }
            XCTAssertEqual(path, Self.missingModelURL.path)
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "ASR model not found at \(Self.missingModelURL.path)."
            )
        }
    }

    // MARK: - Sessionless stream surface

    func test_openStream_whenSessionNotPrepared_shouldResetWithoutSideEffects() throws {
        let engine = try requireEngine()

        XCTAssertNoThrow(try engine.openStream())

        XCTAssertEqual(engine.processedSamples, 0)
        XCTAssertNil(engine.poll())
    }

    func test_push_whenSessionNotOpen_shouldBeIgnored() throws {
        let engine = try requireEngine()

        engine.push([Float](repeating: 0.01, count: 2560))

        XCTAssertEqual(engine.processedSamples, 0, "push without a session must not count samples")
        XCTAssertNil(engine.poll())
    }

    func test_poll_whenInboxEmpty_shouldReturnNil() throws {
        let engine = try requireEngine()

        XCTAssertNil(engine.poll())
    }

    // MARK: - finish (sessionless drain)

    func test_finish_whenSessionless_shouldReturnImmediatelyWithNoEvents() throws {
        let engine = try requireEngine()

        // No session → no job can ever have been dispatched, so the drain
        // loop must break on its first in-flight check (never waiting on the
        // semaphore) and the empty inbox drains to nothing.
        let drained = engine.finish()

        XCTAssertTrue(drained.isEmpty)
        XCTAssertNil(engine.poll())
    }

    // MARK: - close

    func test_close_whenCalledTwice_shouldStaySafe() throws {
        let engine = try requireEngine()

        engine.close() // no C session open — must be a no-op
        engine.close()

        XCTAssertNil(engine.poll())
        XCTAssertEqual(engine.processedSamples, 0)
    }
}
