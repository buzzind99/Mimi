import Foundation
@testable import Mimi
import Testing

/// Tests `ASREngineFactory`'s decision table: mock/nil fallbacks, warm-cache
/// reuse, and stale-model retirement. The warm paths need the native dylib to
/// bind — when it can't (no `MIMI_ASR_DYLIB`, no local/frameworks checkout),
/// those tests are gated off by `.enabled(if:)` over the shared probe
/// `TestEnvironment.nativeASRDylibAvailable` (documented environment
/// exclusion); the mock/nil fallbacks run everywhere.
///
/// The suite is serialized: the factory's warm engine is a process global,
/// so its tests must not race each other. No other suite drives the real
/// factory — the session tests inject their own engine factories.
@Suite("ASREngineFactory", .serialized)
struct ASREngineFactoryTests {

    /// Re-arms the factory's warm cache before every test: retirement
    /// (`retireWarmEngine`) is process-sticky by design, and a previous
    /// test's retire/defer cleanup must not leave the factory handing out
    /// nils to the next one.
    init() {
        ASREngineFactory.rearmWarmCacheForTesting()
    }

    // MARK: - Fixtures

    /// Unique per call: the factory's warm cache is keyed on the path string
    /// only, and a fresh path isolates each test from other suites' warm-ups.
    private func uniqueModelURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimi-factory-\(UUID().uuidString).gguf")
    }

    // MARK: - nil model URL

    @Test("a nil model URL with mocks allowed returns a mock")
    func nilModelURLWithMockAllowedReturnsMock() {
        let engine = ASREngineFactory.makeEngine(modelURL: nil, allowMock: true)

        #expect(engine is MockASREngine)
        #expect(engine?.isMock == true)
    }

    @Test("a nil model URL without mocks returns nil")
    func nilModelURLWithoutMockReturnsNil() {
        let engine = ASREngineFactory.makeEngine(modelURL: nil, allowMock: false)

        #expect(engine == nil)
    }

    // MARK: - dylib unavailable → mock fallback, no caching

    @Test(
        "an unavailable dylib falls back to fresh mocks, uncached",
        .enabled(if: !TestEnvironment.nativeASRDylibAvailable)
    )
    func dylibUnavailableFallsBackToFreshMocks() {
        let url = uniqueModelURL()
        let first = ASREngineFactory.makeEngine(modelURL: url, allowMock: true)
        let second = ASREngineFactory.makeEngine(modelURL: url, allowMock: true)

        #expect(first is MockASREngine)
        #expect(second is MockASREngine)
        #expect(!(first === second), "mocks are never cached")
    }

    @Test(
        "an unavailable dylib without mocks returns nil",
        .enabled(if: !TestEnvironment.nativeASRDylibAvailable)
    )
    func dylibUnavailableWithoutMockReturnsNil() {
        let engine = ASREngineFactory.makeEngine(modelURL: uniqueModelURL(), allowMock: false)

        #expect(engine == nil)
    }

    // MARK: - dylib available → native engine + warm cache

    @Test(
        "an available dylib returns a native engine even for a missing model",
        .enabled(if: TestEnvironment.nativeASRDylibAvailable)
    )
    func dylibAvailableReturnsNativeEngine() {
        let engine = ASREngineFactory.makeEngine(modelURL: uniqueModelURL(), allowMock: false)

        #expect(engine != nil, "init binds the dylib; model existence is prepare-time")
        #expect(engine?.isMock == false)
    }

    @Test(
        "the same model path reuses the process-warm engine",
        .enabled(if: TestEnvironment.nativeASRDylibAvailable)
    )
    func sameModelPathReusesWarmEngine() {
        let url = uniqueModelURL()
        let first = ASREngineFactory.makeEngine(modelURL: url, allowMock: true)
        let second = ASREngineFactory.makeEngine(modelURL: url, allowMock: true)

        #expect(!(first is MockASREngine))
        #expect(first === second, "same model path must reuse the process-warm engine")
    }

    @Test(
        "a changed model path retires the stale engine",
        .enabled(if: TestEnvironment.nativeASRDylibAvailable)
    )
    func changedModelPathRetiresStaleEngine() {
        let firstURL = uniqueModelURL()
        let stale = ASREngineFactory.makeEngine(modelURL: firstURL, allowMock: true)

        let secondURL = uniqueModelURL()
        let replacement = ASREngineFactory.makeEngine(modelURL: secondURL, allowMock: true)

        #expect(!(stale === replacement), "a changed model path retires the stale engine")
        #expect(
            ASREngineFactory.makeEngine(modelURL: secondURL, allowMock: true) === replacement,
            "the replacement becomes the warm engine for its path"
        )
    }

    // MARK: - retireWarmEngine (quit-time teardown)

    @Test(
        "retireWarmEngine releases the cached engine; the factory hands out nothing until re-armed",
        .enabled(if: TestEnvironment.nativeASRDylibAvailable)
    )
    func retireWarmEngineForcesFreshEngine() {
        defer { ASREngineFactory.retireWarmEngine() }
        let url = uniqueModelURL()

        let warm = ASREngineFactory.makeEngine(modelURL: url, allowMock: true)
        ASREngineFactory.retireWarmEngine()

        #expect(
            ASREngineFactory.makeEngine(modelURL: url, allowMock: true) == nil,
            "a retired factory hands out no engines — a warm-up racing the quit teardown must not load a new resident model"
        )

        ASREngineFactory.rearmWarmCacheForTesting()
        #expect(
            !(ASREngineFactory.makeEngine(modelURL: url, allowMock: true) === warm),
            "re-arming clears the cache: the same path builds a fresh engine"
        )
    }

    @Test(
        "retireWarmEngine is a no-op with an empty cache",
        .enabled(if: TestEnvironment.nativeASRDylibAvailable)
    )
    func retireWarmEngineWithEmptyCacheIsNoOp() {
        defer { ASREngineFactory.retireWarmEngine() }
        ASREngineFactory.retireWarmEngine()
        ASREngineFactory.rearmWarmCacheForTesting()

        let engine = ASREngineFactory.makeEngine(modelURL: uniqueModelURL(), allowMock: true)

        #expect(engine?.isMock == false, "the factory still builds engines normally afterwards")
    }

    @Test(
        "retireWarmEngine shuts down the runtime's process-cached models",
        .enabled(if: TestEnvironment.nativeASRDylibAvailable)
    )
    func retireWarmEngineShutsDownRuntimeCaches() throws {
        defer { ASREngineFactory.retireWarmEngine() }
        let url = uniqueModelURL()

        #expect(ASREngineFactory.makeEngine(modelURL: url, allowMock: true) != nil)
        let library = try CrispASRLibrary.open()
        #expect(
            library.hasShutdownSymbol,
            "the pinned runtime must expose the cached-model free (crispasr_shutdown or crispasr_vad_free_cache)"
        )

        ASREngineFactory.retireWarmEngine()
        ASREngineFactory.retireWarmEngine() // empty cache → no C call, must stay safe
    }
}
