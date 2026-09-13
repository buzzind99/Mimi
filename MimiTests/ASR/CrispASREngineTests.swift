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
/// Excluded: the decode/VAD/session internals — real transcription,
/// endpointing, and the drain's in-flight waits need a bound native dylib +
/// GGUF model + Metal pipeline (the fake-library suite covers them without
/// the hardware). Tests that exercise the engine shell cancel
/// (`try Test.cancel`) when the dylib can't bind; the bind-failure test
/// cancels on the inverse condition.
@Suite("CrispASREngine")
struct CrispASREngineTests {

    // MARK: - Fixtures

    /// Missing file used by the prepare tests: pins the thrown
    /// `.modelNotFound` case (path + description). That the guard fires
    /// before any C call is a property only a fake library could prove —
    /// the fake-library suite covers the C-facing `prepare` paths.
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

        #expect(engine.pushedSamples == 0, "push without a session must not count samples")
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

        engine.push([Float](repeating: 0.01, count: 2560))
        #expect(engine.pushedSamples == 0, "push after close stays ignored (finishing latched)")
    }

    // MARK: - fallbackBackend (detector-less name guess)

    @Test("fallbackBackend guesses the family from the GGUF file name")
    func fallbackBackendFollowsFileName() {
        #expect(
            CrispASREngine.fallbackBackend(modelPath: "/models/funasr-nano-2512-q8_0.gguf") == "funasr"
        )
        #expect(
            CrispASREngine.fallbackBackend(modelPath: "/models/sensevoice-small-q8_0.gguf") == "sensevoice"
        )
        #expect(
            CrispASREngine.fallbackBackend(modelPath: "/models/FUNASR-Nano.Q8_0.GGUF") == "funasr",
            "the guess is case-insensitive"
        )
        #expect(
            CrispASREngine.fallbackBackend(modelPath: "/tmp/mimi-crisp-missing.gguf") == "sensevoice",
            "an unknown name keeps the Lite default"
        )
    }

    // MARK: - decode-text sanitization

    @Test("sanitizeDecodeText strips non-speech tags in every spelling")
    func sanitizeStripsNonSpeechTags() {
        #expect(CrispASREngine.sanitizeDecodeText("<sil>") == "")
        #expect(CrispASREngine.sanitizeDecodeText("<SIL>") == "")
        #expect(CrispASREngine.sanitizeDecodeText("<|sil|>") == "")
        #expect(CrispASREngine.sanitizeDecodeText("</sil>") == "")
        #expect(CrispASREngine.sanitizeDecodeText("/sil") == "")
        #expect(CrispASREngine.sanitizeDecodeText("/SIL") == "")
        #expect(CrispASREngine.sanitizeDecodeText("/noise") == "")
        #expect(CrispASREngine.sanitizeDecodeText("<noise>") == "")
        #expect(CrispASREngine.sanitizeDecodeText("<|Music|>") == "")
        #expect(CrispASREngine.sanitizeDecodeText("<unk>") == "")
        #expect(CrispASREngine.sanitizeDecodeText(" <sil> <noise> ") == "")
        #expect(CrispASREngine.sanitizeDecodeText("/sil /noise /sil") == "")
    }

    @Test("sanitizeDecodeText keeps speech and cleans up around stripped tags")
    func sanitizeKeepsSpeech() {
        #expect(CrispASREngine.sanitizeDecodeText("こんにちは。") == "こんにちは。")
        #expect(CrispASREngine.sanitizeDecodeText("こんにちは <sil> です。") == "こんにちはです。")
        #expect(CrispASREngine.sanitizeDecodeText("こんにちは /sil です。") == "こんにちはです。")
        #expect(CrispASREngine.sanitizeDecodeText("  こんにちは。  ") == "こんにちは。")
    }

    @Test("sanitizeDecodeText joins ASR's space-separated CJK tokens")
    func sanitizeJoinsCJKTokens() {
        #expect(CrispASREngine.sanitizeDecodeText("参加 者 だと 思 って") == "参加者だと" + "思って")
        #expect(CrispASREngine.sanitizeDecodeText("いの ね、そう いっ た") == "いのね、そういった")
        #expect(CrispASREngine.sanitizeDecodeText("求め られ てい ません ので") == "求められていませんので")
        #expect(CrispASREngine.sanitizeDecodeText("参加\u{3000}者") == "参加者")
        #expect(CrispASREngine.sanitizeDecodeText("思\nって") == "思って")
    }

    @Test("sanitizeDecodeText keeps whitespace next to Latin and digits")
    func sanitizeKeepsNonCJKWhitespace() {
        #expect(CrispASREngine.sanitizeDecodeText("hello world です") == "hello world です")
        #expect(CrispASREngine.sanitizeDecodeText("600 回") == "600 回")
        #expect(CrispASREngine.sanitizeDecodeText("2 人 です") == "2 人です")
        #expect(CrispASREngine.sanitizeDecodeText("A B") == "A B")
    }

    @Test("isCJKSurface classifies kana, kanji, and CJK punctuation")
    func cjkSurfaceClassification() throws {
        #expect(try CrispASREngine.isCJKSurface(#require("思".unicodeScalars.first)))
        #expect(try CrispASREngine.isCJKSurface(#require("っ".unicodeScalars.first)))
        #expect(try CrispASREngine.isCJKSurface(#require("ー".unicodeScalars.first)))
        #expect(try CrispASREngine.isCJKSurface(#require("、".unicodeScalars.first)))
        #expect(try CrispASREngine.isCJKSurface(#require("々".unicodeScalars.first)))
        #expect(try !CrispASREngine.isCJKSurface(#require("a".unicodeScalars.first)))
        #expect(try !CrispASREngine.isCJKSurface(#require("6".unicodeScalars.first)))
        #expect(try !CrispASREngine.isCJKSurface(#require(" ".unicodeScalars.first)))
    }
}
