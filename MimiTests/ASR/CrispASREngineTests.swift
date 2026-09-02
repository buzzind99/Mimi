import Foundation
@testable import Mimi
import Testing

/// Tests the `CrispASREngine` paths reachable without a loaded GGUF model or
/// a Metal pipeline: the init bind-failure throw (assertable only when the
/// dylib is absent), `prepare`'s missing-model guard, `openStream`'s state
/// reset, `push`'s session guard, `poll` on an empty inbox, `close`
/// idempotency, and `finish`'s sessionless drain (no in-flight jobs →
/// immediate empty drain).
///
/// Excluded (see the exclusions inventory): the decode/VAD/session internals
/// — real transcription, endpointing, and the drain's in-flight waits need a
/// bound native dylib + GGUF model + Metal pipeline. Tests that exercise the
/// engine shell cancel (`try Test.cancel`) when the dylib can't bind; the
/// bind-failure test cancels on the inverse condition.
@Suite("CrispASREngine")
struct CrispASREngineTests {

    // MARK: - Fixtures

    /// Exists only to prove the model-file guard fires before any C call.
    private static let missingModelURL = URL(fileURLWithPath: "/tmp/mimi-crisp-missing.gguf")

    private let engine: CrispASREngine?

    init() {
        // Succeeds iff the dylib binds (init never touches the model file).
        engine = try? CrispASREngine(modelPath: Self.missingModelURL)
    }

    private func requireEngine() throws -> CrispASREngine {
        guard let engine else {
            try Test.cancel("native runtime is not available in this environment")
        }
        return engine
    }

    // MARK: - init / binding

    @Test("init throws .runtimeNotFound when the dylib is unavailable")
    func initThrowsRuntimeNotFoundWhenDylibUnavailable() throws {
        guard engine == nil else {
            try Test.cancel("native runtime is available in this environment")
        }

        let thrown = #expect(throws: ASREngineError.self) {
            try CrispASREngine(modelPath: Self.missingModelURL)
        }
        let error = try #require(thrown)

        guard case let .runtimeNotFound(detail) = error else {
            Issue.record("expected .runtimeNotFound, got \(error)")
            return
        }
        #expect(!detail.isEmpty)
    }

    @Test("the native engine is not a mock")
    func isMockIsFalse() throws {
        let engine = try requireEngine()

        #expect(!engine.isMock)
    }

    // MARK: - prepare (missing model)

    @Test("prepare throws .modelNotFound with the missing model's path")
    func prepareWhenModelMissingThrowsModelNotFound() throws {
        let engine = try requireEngine()

        let thrown = #expect(throws: ASREngineError.self) {
            try engine.prepare()
        }
        let error = try #require(thrown)

        guard case let .modelNotFound(path) = error else {
            Issue.record("expected .modelNotFound, got \(error)")
            return
        }
        #expect(path == Self.missingModelURL.path)
        #expect(
            error.errorDescription == "ASR model not found at \(Self.missingModelURL.path)."
        )
    }

    // MARK: - Sessionless stream surface

    @Test("openStream without a prepared session resets without side effects")
    func openStreamWhenSessionNotPrepared() throws {
        let engine = try requireEngine()

        try engine.openStream()

        #expect(engine.processedSamples == 0)
        #expect(engine.poll() == nil)
    }

    @Test("push without an open session is ignored")
    func pushWhenSessionNotOpenIsIgnored() throws {
        let engine = try requireEngine()

        engine.push([Float](repeating: 0.01, count: 2560))

        #expect(engine.processedSamples == 0, "push without a session must not count samples")
        #expect(engine.poll() == nil)
    }

    @Test("poll on an empty inbox returns nil")
    func pollWhenInboxEmpty() throws {
        let engine = try requireEngine()

        #expect(engine.poll() == nil)
    }

    // MARK: - finish (sessionless drain)

    @Test("finish without a session drains immediately with no events")
    func finishWhenSessionless() throws {
        let engine = try requireEngine()

        // No session → no job can ever have been dispatched, so the drain
        // loop must break on its first in-flight check (never waiting on the
        // semaphore) and the empty inbox drains to nothing.
        let drained = engine.finish()

        #expect(drained.isEmpty)
        #expect(engine.poll() == nil)
    }

    // MARK: - close

    @Test("closing twice without a C session stays safe")
    func closeTwiceStaysSafe() throws {
        let engine = try requireEngine()

        engine.close() // no C session open — must be a no-op
        engine.close()

        #expect(engine.poll() == nil)
        #expect(engine.processedSamples == 0)
    }
}
