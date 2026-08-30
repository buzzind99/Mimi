@testable import Mimi
import XCTest

/// Tests `ASREngineFactory`'s decision table: mock/nil fallbacks, warm-cache
/// reuse, and stale-model retirement. The warm paths need the native dylib to
/// bind — when it can't (no `MIMI_ASR_DYLIB`, no local/frameworks checkout),
/// those assertions skip (documented environment exclusion); the mock/nil
/// fallbacks run everywhere.
final class ASREngineFactoryTests: XCTestCase {

    // MARK: - Fixtures

    /// Mirrors the factory: `CrispASREngine.init` binds the dylib but never
    /// touches the model file (existence is `prepare`'s job), so a
    /// nonexistent path probes dylib availability without side effects.
    private static let missingModelURL = URL(fileURLWithPath: "/tmp/mimi-factory-missing.gguf")

    private static let dylibAvailable: Bool = (try? CrispASREngine(modelPath: missingModelURL)) != nil

    /// Unique per call: the factory's warm cache is keyed on the path string
    /// only, and a fresh path isolates each test from other suites' warm-ups.
    private func uniqueModelURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimi-factory-\(UUID().uuidString).gguf")
    }

    // MARK: - nil model URL

    func test_makeEngine_whenModelURLNil_whenMockAllowed_shouldReturnMock() {
        let engine = ASREngineFactory.makeEngine(modelURL: nil, allowMock: true)

        XCTAssertTrue(engine is MockASREngine)
        XCTAssertEqual(engine?.isMock, true)
    }

    func test_makeEngine_whenModelURLNil_whenMockNotAllowed_shouldReturnNil() {
        let engine = ASREngineFactory.makeEngine(modelURL: nil, allowMock: false)

        XCTAssertNil(engine)
    }

    // MARK: - dylib unavailable → mock fallback, no caching

    func test_makeEngine_whenDylibUnavailable_shouldFallBackToFreshMocks() throws {
        try XCTSkipIf(Self.dylibAvailable, "native runtime is available in this environment")

        let url = uniqueModelURL()
        let first = ASREngineFactory.makeEngine(modelURL: url, allowMock: true)
        let second = ASREngineFactory.makeEngine(modelURL: url, allowMock: true)

        XCTAssertTrue(first is MockASREngine)
        XCTAssertTrue(second is MockASREngine)
        XCTAssertFalse(first === second, "mocks are never cached")
    }

    func test_makeEngine_whenDylibUnavailable_whenMockNotAllowed_shouldReturnNil() throws {
        try XCTSkipIf(Self.dylibAvailable, "native runtime is available in this environment")

        let engine = ASREngineFactory.makeEngine(modelURL: uniqueModelURL(), allowMock: false)

        XCTAssertNil(engine)
    }

    // MARK: - dylib available → native engine + warm cache

    func test_makeEngine_whenDylibAvailable_whenMockNotAllowed_shouldReturnNativeEngine() throws {
        try XCTSkipUnless(Self.dylibAvailable, "native runtime is not available in this environment")

        let engine = ASREngineFactory.makeEngine(modelURL: uniqueModelURL(), allowMock: false)

        XCTAssertNotNil(engine, "init binds the dylib; model existence is prepare-time")
        XCTAssertEqual(engine?.isMock, false)
    }

    func test_makeEngine_whenDylibAvailable_forSameModelPath_shouldReuseWarmEngine() throws {
        try XCTSkipUnless(Self.dylibAvailable, "native runtime is not available in this environment")

        let url = uniqueModelURL()
        let first = ASREngineFactory.makeEngine(modelURL: url, allowMock: true)
        let second = ASREngineFactory.makeEngine(modelURL: url, allowMock: true)

        XCTAssertFalse(first is MockASREngine)
        XCTAssertTrue(first === second, "same model path must reuse the process-warm engine")
    }

    func test_makeEngine_whenDylibAvailable_whenModelPathChanges_shouldRetireStaleEngine() throws {
        try XCTSkipUnless(Self.dylibAvailable, "native runtime is not available in this environment")

        let firstURL = uniqueModelURL()
        let stale = ASREngineFactory.makeEngine(modelURL: firstURL, allowMock: true)

        let secondURL = uniqueModelURL()
        let replacement = ASREngineFactory.makeEngine(modelURL: secondURL, allowMock: true)

        XCTAssertFalse(stale === replacement, "a changed model path retires the stale engine")
        XCTAssertTrue(
            ASREngineFactory.makeEngine(modelURL: secondURL, allowMock: true) === replacement,
            "the replacement becomes the warm engine for its path"
        )
    }
}
