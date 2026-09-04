import Foundation
@testable import Mimi
import Testing

/// Live-runtime suite for `CrispASREngine`: exercises the real dlopen-bound
/// `CrispASRLibrary` — symbol binding (`bind(from:)` via `open()`), the VAD
/// model-path resolution, `openSession` over the dev GGUF, the
/// `transcribeText` FFI marshalling, the `vadSlices` ABI parameters — plus
/// one end-to-end prepare → openStream → push → poll → finish pass with
/// synthesized 16 kHz speech/silence cycles.
///
/// `.serialized`: the real library's dlopen handle and the C library's VAD
/// model cache are process-global. Gated on
/// `TestEnvironment.crispRuntimeAvailable` (dylib binds + dev model
/// installed); cancels everywhere else. The VAD model is deliberately not
/// part of the gate — when it is missing the engine degrades to the
/// forced-final cap, which the end-to-end pass pins deterministically. All
/// waits are bounded (~30 s budget); no bare sleeps.
@Suite("CrispASREngine (live runtime)", .serialized, .enabled(if: TestEnvironment.crispRuntimeAvailable))
struct CrispASREngineLiveTests {

    // MARK: - Helpers

    private func session(_ engine: CrispASREngine) -> OpaquePointer? {
        engine.lock.withLock { engine.session }
    }

    private func makePreparedEngine() throws -> CrispASREngine {
        let modelURL = try #require(ModelTestFixtures.repoModelURL)
        let engine = try CrispASREngine(modelPath: modelURL)
        try engine.prepare()
        return engine
    }

    /// Alternating 0.25 s bursts of a 220 Hz sine and silence — speech-like
    /// for the VAD, loud for the RMS backstop.
    private func speechCycles(samples: Int) -> [Float] {
        (0 ..< samples).map { index -> Float in
            guard (index / (CrispASREngine.sampleRate / 4)) % 2 == 0 else { return 0 }
            let phase = Float(index) * 220.0 / Float(CrispASREngine.sampleRate) * 2 * .pi
            return 0.2 * sin(phase)
        }
    }

    // MARK: - Library binding

    @Test("the real library binds the C symbols and resolves the VAD model when present")
    func libraryBindsAndResolvesVADModel() throws {
        let library = try CrispASRLibrary.open()

        #expect(library.hasVADSymbols)
        if let vadPath = library.vadModelPath {
            #expect(FileManager.default.fileExists(atPath: vadPath))
        }
    }

    @Test("vadSlices round-trips the ABI on the real VAD model")
    func vadSlicesABIRoundTrip() throws {
        let library = try CrispASRLibrary.open()
        guard library.hasVADSymbols, let vadPath = library.vadModelPath else {
            try Test.cancel("VAD dispatcher or firered-vad.gguf is unavailable (engine degrades to cap-only)")
        }

        let pcm = speechCycles(samples: 4 * CrispASREngine.sampleRate)
        let sliceResult = pcm.withUnsafeBufferPointer { buf in
            library.vadSlices(
                modelPath: vadPath, pcm: Span(_unsafeElements: buf),
                parameters: CrispASRVADParameters(
                    sampleRate: CrispASREngine.sampleRate, threshold: CrispASREngine.vadThreshold,
                    minSpeechMS: CrispASREngine.vadMinSpeechMS,
                    minSilenceMS: CrispASREngine.vadMinSilenceMS, padMS: CrispASREngine.vadPadMS
                )
            )
        }
        let slices = try #require(sliceResult, "the dispatcher-backed ABI must not return nil")

        #expect(slices.count >= 0, "a present model must not fail the C call (negative code)")
        if slices.count > 0 {
            let spans = try #require(slices.spans)
            for span in 0 ..< Int(slices.count) {
                let start = spans[2 * span]
                let end = spans[2 * span + 1]
                #expect(start >= 0 && end <= 4.0 && start <= end, "spans are seconds within the input")
            }
        }
        library.vadFree(slices.spans)
    }

    // MARK: - Session FFI

    @Test("prepare opens a C session over the dev model and close releases it")
    func prepareOpensAndCloseReleasesSession() throws {
        let engine = try makePreparedEngine()

        #expect(session(engine) != nil)
        #expect(engine.languageCode == "ja")
        engine.close()
        #expect(session(engine) == nil)
    }

    @Test("transcribeText round-trips PCM through the FFI and returns concatenated segment text")
    func transcribeTextMarshalling() throws {
        let engine = try makePreparedEngine()
        defer { engine.close() }

        let pcm = [Float](repeating: 0, count: 2 * CrispASREngine.sampleRate) // 2 s at the conv floor
        let text = pcm.withUnsafeBufferPointer { buf in
            engine.lib.transcribeText(
                session: session(engine), pcm: Span(_unsafeElements: buf), languageCode: "ja"
            )
        }

        #expect(text != nil, "the FFI call must round-trip; empty text is a valid result")
    }

    // MARK: - End-to-end

    /// Degraded mode makes the pipeline deterministic on synthesized audio:
    /// with VAD off, the 12 s forced-final cap is the only endpoint, and the
    /// RMS backstop guarantees loud audio reaches the decode. Pinned via the
    /// latency readback (processed samples), not ASR output quality.
    @Test("prepare → openStream → push → poll → finish processes a capped utterance end-to-end")
    func endToEndSessionPipeline() async throws {
        let engine = try makePreparedEngine()
        try engine.openStream()
        // openStream re-enables VAD; degrade after it so the 12 s forced-final
        // cap is the only endpoint on synthesized audio.
        engine.lock.withLock { engine.vadEnabled = false }

        let cap = CrispASREngine.utteranceCapSamples
        var pushed = 0
        while pushed < cap {
            let chunk = min(CrispASREngine.sampleRate, cap - pushed)
            engine.push(speechCycles(samples: chunk))
            pushed += chunk
        }

        await pollUntilOffMain(timeout: 30) { engine.processedSamples >= cap }

        #expect(engine.processedSamples == cap, "the cap final must decode the whole utterance")
        let drained = engine.finish()
        for event in drained {
            guard case .final = event else {
                Issue.record("finish must drain only finals, got \(event)")
                continue
            }
        }
        engine.close()
    }
}
