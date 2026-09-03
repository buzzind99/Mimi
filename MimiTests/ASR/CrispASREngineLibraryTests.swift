import Foundation
@testable import Mimi
import Testing

/// Tests the full `CrispASREngine` state machine over a scripted fake
/// library (`CrispASRLibraryAPI` injection): push → VAD span → endpoint
/// final, the zero-span speechless discard, VAD failure degradation and
/// throttling, decode-failure throttling (×1 then every 32nd), partial
/// cadence + zero-padding below the 2 s conv floor, stale-generation drops,
/// the forced-final cap (loud vs silent), `finish()`'s flush decode + drain,
/// and the post-final window trim.
///
/// Runs on every machine — no dlopen, no model, no Metal: the fake bypasses
/// the library seam and the vad/decode queues are per-engine instance state,
/// so the suite is NOT `.serialized`. Timelines converge through bounded
/// `waitUntil` polls on the fake's recorded calls and the engine's
/// lock-guarded state, never bare sleeps.
@Suite("CrispASREngine (fake library)")
struct CrispASREngineLibraryTests {

    // MARK: - Fixtures

    private let tmp: TemporaryDirectory

    init() throws {
        tmp = try TemporaryDirectory(prefix: "mimi-crisp-fake")
    }

    /// 1 s of loud PCM (RMS 0.1 ≫ speechRMS) — "speech" for the RMS backstop.
    private var loudSecond: [Float] {
        [Float](repeating: 0.1, count: CrispASREngine.sampleRate)
    }

    private var silentSecond: [Float] {
        [Float](repeating: 0, count: CrispASREngine.sampleRate)
    }

    // MARK: - Helpers

    private func makePreparedEngine(_ library: FakeCrispASRLibrary) throws -> CrispASREngine {
        let modelURL = try tmp.write(Data("gguf".utf8), named: "model.gguf")
        let engine = try CrispASREngine(modelPath: modelURL, library: library)
        try engine.prepare()
        try engine.openStream()
        return engine
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Reads engine state under its lock — jobs mutate it on their queues.
    private func state<T>(_ engine: CrispASREngine, _ read: () -> T) -> T {
        engine.lock.withLock { read() }
    }

    /// Drains `poll()` until a final appears (bounded); returns it, or nil
    /// on timeout.
    private func pollFinal(_ engine: CrispASREngine) async -> ASREvent? {
        var final: ASREvent?
        await waitUntil {
            guard let event = engine.poll() else { return false }
            if case .final = event {
                final = event
                return true
            }
            return false
        }
        return final
    }

    private func requireFinal(_ event: ASREvent?, text: String, start: Int, end: Int) {
        guard case let .final(actualText, actualStart, actualEnd, actualLang) = event else {
            Issue.record("expected .final, got \(String(describing: event))")
            return
        }
        #expect(actualText == text)
        #expect(actualStart == start)
        #expect(actualEnd == end)
        #expect(actualLang == "ja")
    }

    // MARK: - Endpointing

    @Test("a VAD span plus confirmed silence finalizes the utterance with one clean final")
    func vadSpanThenSilenceFinalizes() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.spans([(start: 0.0, end: 1.0)])]
        library.transcribeReplies = ["", "こんにちは。"] // window partial (no event), utterance final
        let engine = try makePreparedEngine(library)

        engine.push(loudSecond)
        await waitUntil { library.transcribeCalls.count == 1 }
        engine.push([Float](repeating: 0, count: 20000)) // 1.25 s closes the confirmed-silence endpoint

        let final = await pollFinal(engine)
        requireFinal(final, text: "こんにちは。", start: 0, end: 16000)
        #expect(
            library.transcribeCalls.map(\.pcmCount) == [32000, 36000],
            "partial = padded 1 s window, final = the whole 2.25 s utterance"
        )
        #expect(engine.poll() == nil, "the final must be the last event")
    }

    @Test("a zero-span VAD verdict discards the speechless utterance")
    func speechlessVerdictDiscardsUtterance() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.speechless]
        let engine = try makePreparedEngine(library)

        engine.push([Float](repeating: 0.1, count: 48000)) // 3 s, past the discard floor
        await waitUntil { self.state(engine) { engine.utterance.isEmpty } } // discard observed

        engine.push(loudSecond)
        await waitUntil { library.vadCalls.count == 2 }

        #expect(
            library.vadCalls[1].count == 16000,
            "the discarded utterance must not accumulate into the next VAD snapshot"
        )
        #expect(state(engine) { engine.utteranceGeneration } == 2)
        #expect(library.transcribeCalls.isEmpty, "speechless audio must never decode")
        #expect(engine.poll() == nil)
    }

    @Test("a final trims the finalized span plus the context tail from the rolling window")
    func finalTrimsWindow() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [
            .spans([(start: 0.0, end: 1.0)]), // VAD #1: 2 s span → first partial
            .spans([(start: 0.0, end: 1.0)]), // VAD #2: closed span → endpoint final
            .spans([(start: 0.0, end: 3.25)]) // VAD #3: open span at the buffer end → no endpoint
        ]
        library.transcribeReplies = ["", "ファイナル。", ""]
        let engine = try makePreparedEngine(library)

        engine.push([Float](repeating: 0.1, count: 2 * CrispASREngine.sampleRate))
        await waitUntil { library.transcribeCalls.count == 1 }
        engine.push([Float](repeating: 0, count: 20000))
        await waitUntil { library.transcribeCalls.count == 2 }
        engine.push(loudSecond) // speech resumes on the trimmed window
        await waitUntil { library.transcribeCalls.count == 3 }

        #expect(library.transcribeCalls.map(\.pcmCount) == [
            32000, // first partial: the 2 s window at the conv floor
            52000, // final: the whole 3.25 s utterance redecode
            48800 // next partial: window minus the finalized span minus the kept tail
        ])
        requireFinal(await pollFinal(engine), text: "ファイナル。", start: 0, end: 16000)
    }

    // MARK: - VAD failures

    @Test("a fatal VAD failure (−3) degrades to cap-only finalization and reports once")
    func fatalVADFailureDegradesToCapFinal() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.failure(-3)]
        library.transcribeReplies = ["キャップ。"]
        let engine = try makePreparedEngine(library)
        let errors = ErrorRecorder()
        engine.onEngineError = { errors.record($0) }

        engine.push(loudSecond) // VAD #1 → immediate degrade
        await waitUntil { !errors.all.isEmpty }
        #expect(errors.all == ["VAD failed (-3) — falling back to cap-only finalization"])
        #expect(state(engine) { engine.vadEnabled } == false)

        engine.push([Float](repeating: 0.1, count: 12 * CrispASREngine.sampleRate)) // loud cap
        requireFinal(await pollFinal(engine), text: "キャップ。", start: 0, end: 208_000)
        #expect(library.vadCalls.count == 1, "degraded mode must not dispatch more VAD passes")
        #expect(errors.all.count == 1)
    }

    @Test("three transient VAD failures disable VAD with a single report")
    func transientVADFailuresDisableAfterThird() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.failure(-1)]
        let engine = try makePreparedEngine(library)
        let errors = ErrorRecorder()
        engine.onEngineError = { errors.record($0) }

        for failure in 1 ... 3 {
            engine.push(loudSecond)
            await waitUntil { self.state(engine) { engine.consecutiveVADFailures } == failure }
        }

        #expect(state(engine) { engine.vadEnabled } == false)
        #expect(errors.all == ["VAD failed (-1) — falling back to cap-only finalization"])
        #expect(library.transcribeCalls.isEmpty)
    }

    @Test("the forced-final cap discards a silent degraded utterance without decoding")
    func silentCapDiscardsWithoutDecode() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.failure(-3)]
        let engine = try makePreparedEngine(library)
        let errors = ErrorRecorder()
        engine.onEngineError = { errors.record($0) }

        engine.push(silentSecond) // VAD #1 → degrade; utterance stays silent
        await waitUntil { !errors.all.isEmpty }

        engine.push([Float](repeating: 0, count: 12 * CrispASREngine.sampleRate)) // silent cap
        await waitUntil { self.state(engine) { engine.utterance.isEmpty } }

        #expect(library.transcribeCalls.isEmpty, "the RMS backstop must block the cap decode")
        #expect(engine.poll() == nil)
    }

    // MARK: - Decode failures

    @Test("decode failures report at ×1 and then only every 32nd consecutive failure")
    func decodeFailuresThrottleToFirstAndEvery32nd() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.failure(-3)] // degrade → deterministic cap finals
        library.transcribeReplies = [nil] // every decode fails at the C boundary
        library.recordTranscribePcm = false
        let engine = try makePreparedEngine(library)
        let errors = ErrorRecorder()
        engine.onEngineError = { errors.record($0) }

        engine.push(silentSecond) // VAD #1 → degrade (no decode: silent, short)
        await waitUntil { !errors.all.isEmpty }

        let cap = CrispASREngine.utteranceCapSamples
        for push in 0 ..< 32 {
            engine.push([Float](repeating: 0.1, count: cap))
            let expected = library.transcribeCalls.count + 1
            await waitUntil { library.transcribeCalls.count >= expected }
            #expect(library.transcribeCalls.count == push + 1)
        }

        #expect(errors.all == [
            "VAD failed (-3) — falling back to cap-only finalization",
            "ASR decode failed (×1)",
            "ASR decode failed (×32)"
        ])
        #expect(state(engine) { engine.consecutiveDecodeFailures } == 32)
    }

    // MARK: - Partials

    @Test("partials follow confirmed speech at the 1 s cadence and zero-pad below the 2 s floor")
    func partialCadenceAndZeroPadding() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [
            .spans([(start: 0.0, end: 1.0)]), // VAD #1: speech to 1 s → first partial
            .spans([(start: 0.0, end: 1.5)]), // VAD #2: 0.5 s of new speech — under the cadence
            .spans([(start: 0.0, end: 2.0)]) // VAD #3: 1 s of new speech since the decode
        ]
        library.transcribeReplies = [""] // partials never post events
        let engine = try makePreparedEngine(library)

        engine.push(loudSecond)
        await waitUntil { library.transcribeCalls.count == 1 }

        #expect(library.transcribeCalls[0].pcmCount == 2 * CrispASREngine.sampleRate)
        #expect(Array(library.transcribeCalls[0].pcm.prefix(16000)) == loudSecond)
        #expect(
            library.transcribeCalls[0].pcm[16000...].allSatisfy { $0 == 0 },
            "the 1 s window must be zero-padded to the 2 s conv floor"
        )

        engine.push([Float](repeating: 0.1, count: 8000)) // 0.5 s more speech
        await waitUntil { self.state(engine) { engine.vadAnalyzedThroughSample } == 24000 }
        #expect(library.transcribeCalls.count == 1, "0.5 s of confirmed new speech is below the cadence")

        engine.push([Float](repeating: 0.1, count: 8000)) // crosses 1 s since the last decode
        await waitUntil { library.transcribeCalls.count == 2 }
        #expect(library.transcribeCalls[1].pcmCount == 32000, "a 2 s window needs no padding")
    }

    @Test("a VAD result for a closed generation is dropped")
    func staleGenerationVADResultIsDropped() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.spans([(start: 0.0, end: 1.0)])]
        library.transcribeReplies = ["ファイナル。"]
        library.vadHoldSemaphore = DispatchSemaphore(value: 0)
        library.transcribeHoldSemaphore = DispatchSemaphore(value: 0)
        let engine = try makePreparedEngine(library)

        engine.push(loudSecond) // VAD #1 dispatched, held inside the fake
        await waitUntil { library.vadCalls.count == 1 && library.vadEntered }

        engine.push([Float](repeating: 0.1, count: 12 * CrispASREngine.sampleRate)) // cap final decode
        // The fake blocks before recording the call, so only entry is
        // observable while held — waiting on the count here would always
        // burn the full timeout.
        await waitUntil { library.transcribeEntered }

        library.transcribeHoldSemaphore?.signal() // the decode closes generation 1
        await waitUntil { self.state(engine) { engine.utteranceGeneration } == 2 }

        library.vadHoldSemaphore?.signal() // VAD #1 resumes into a stale generation
        await waitUntil { library.vadFreeCount == 1 }

        #expect(state(engine) { engine.vadAnalyzedThroughSample } == 0)
        #expect(state(engine) { engine.utteranceHasSpeech } == false)
        #expect(state(engine) { engine.vadLastSpeechEndSample } == nil)
        #expect(state(engine) { engine.utterance.isEmpty })
        requireFinal(await pollFinal(engine), text: "ファイナル。", start: 0, end: 208_000)
    }

    // MARK: - finish()

    @Test("finish flush-decodes a speechful open utterance and drains the final")
    func finishFlushesSpeechfulUtterance() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.spans([(start: 0.0, end: 1.0)])]
        library.transcribeReplies = ["", "フラッシュ。"] // window partial, flush decode
        let engine = try makePreparedEngine(library)

        engine.push(loudSecond)
        await waitUntil { library.transcribeCalls.count == 1 } // speech confirmed

        let drained = engine.finish()

        #expect(drained.count == 1)
        requireFinal(drained.first, text: "フラッシュ。", start: 0, end: 16000)
        #expect(library.transcribeCalls.count == 2)
        let flush = library.transcribeCalls[1]
        #expect(flush.pcmCount == 2 * CrispASREngine.sampleRate)
        #expect(flush.pcm[16000...].allSatisfy { $0 == 0 }, "the flush pads the 1 s utterance")
        #expect(engine.poll() == nil, "finish drains the inbox")
    }

    @Test("finish skips the flush decode for a speechless utterance")
    func finishSkipsSpeechlessFlush() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.failure(-3)]
        let engine = try makePreparedEngine(library)
        let errors = ErrorRecorder()
        engine.onEngineError = { errors.record($0) }

        engine.push(silentSecond) // VAD #1 → degrade; utterance silent and short
        await waitUntil { !errors.all.isEmpty }

        let drained = engine.finish()

        #expect(drained.isEmpty)
        #expect(
            library.transcribeCalls.isEmpty,
            "the RMS backstop must keep known-silent audio out of the flush decode"
        )
    }
}

/// Thread-safe sink for `onEngineError` (called from the engine's job
/// queues, not the test thread).
private final class ErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(_ message: String) {
        lock.withLock { messages.append(message) }
    }

    var all: [String] {
        lock.withLock { messages }
    }
}

/// Scripted `CrispASRLibraryAPI` double. Ordered replies repeat their
/// last element; optional gates pin async interleavings (a VAD result
/// held inside the fake while a decode closes its generation).
private final class FakeCrispASRLibrary: CrispASRLibraryAPI, @unchecked Sendable {
    enum VADReply {
        case spans([(start: Float, end: Float)])
        case speechless
        case failure(Int32)
    }

    struct TranscribeCall {
        let pcmCount: Int
        let pcm: [Float]
        let languageCode: String
    }

    private let lock = NSLock()

    var vadModelPathValue: String? = "/tmp/fake-firered-vad.gguf"
    var vadReplies: [VADReply] = [.speechless]
    var transcribeReplies: [String?] = [""]
    var recordTranscribePcm = true
    /// Set → `vadSlices` marks the call entered and blocks until released.
    var vadHoldSemaphore: DispatchSemaphore?
    /// Set → `transcribeText` marks the call entered and blocks until released.
    var transcribeHoldSemaphore: DispatchSemaphore?

    private(set) var vadCalls: [[Float]] = []
    private(set) var vadEntered = false
    private(set) var transcribeCalls: [TranscribeCall] = []
    private(set) var transcribeEntered = false
    private(set) var vadFreeCount = 0
    private(set) var gpuBackends: [String] = []
    private(set) var openSessionCount = 0
    private(set) var closeSessionCount = 0

    var vadModelPath: String? {
        vadModelPathValue
    }

    func setGpuBackend(_ name: String) {
        lock.withLock { gpuBackends.append(name) }
    }

    func openSession(modelPath: String, backend: String) -> OpaquePointer? {
        lock.withLock { openSessionCount += 1 }
        return OpaquePointer(bitPattern: 0x1A55_1E55)
    }

    func closeSession(_ session: OpaquePointer?) {
        lock.withLock { closeSessionCount += 1 }
    }

    func transcribeText(
        session: OpaquePointer?, pcm: borrowing Span<Float>, languageCode: String
    ) -> String? {
        let pcmCopy = pcm.withUnsafeBufferPointer { Array($0) }
        if let hold = transcribeHoldSemaphore {
            lock.withLock { transcribeEntered = true }
            hold.wait()
        }
        lock.withLock {
            transcribeCalls.append(TranscribeCall(
                pcmCount: pcmCopy.count,
                pcm: recordTranscribePcm ? pcmCopy : [],
                languageCode: languageCode
            ))
        }
        let index = min(transcribeCalls.count - 1, transcribeReplies.count - 1)
        return transcribeReplies[index]
    }

    func vadSlices(
        modelPath: String,
        pcm: borrowing Span<Float>,
        parameters: CrispASRVADParameters
    ) -> (count: Int32, spans: UnsafeMutablePointer<Float>?)? {
        lock.withLock { vadCalls.append(pcm.withUnsafeBufferPointer { Array($0) }) }
        if let hold = vadHoldSemaphore {
            lock.withLock { vadEntered = true }
            hold.wait()
        }
        let reply = vadReplies[min(vadCalls.count - 1, vadReplies.count - 1)]
        switch reply {
        case let .failure(code):
            return (code, nil)
        case .speechless:
            return (0, nil)
        case let .spans(pairs):
            let spans = UnsafeMutablePointer<Float>.allocate(capacity: pairs.count * 2)
            for (index, pair) in pairs.enumerated() {
                spans[2 * index] = pair.start
                spans[2 * index + 1] = pair.end
            }
            return (Int32(pairs.count), spans)
        }
    }

    func vadFree(_ spans: UnsafeMutablePointer<Float>?) {
        spans?.deallocate()
        lock.withLock { vadFreeCount += 1 }
    }
}
