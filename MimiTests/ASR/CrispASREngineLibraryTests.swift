import Foundation
@testable import Mimi
import Testing

/// Tests the full `CrispASREngine` state machine over a scripted fake
/// library (`CrispASRLibraryAPI` injection): push → VAD span → endpoint
/// final, `.partial` draft events, the zero-span speechless discard and its
/// cursor reset, the nil-VAD-reply skip, VAD failure degradation and
/// throttling, decode-failure throttling (×1 then every 32nd), partial
/// cadence + zero-padding below the 2 s conv floor, stale-generation drops,
/// and the post-final window trim. Session lifecycle (`prepare`/`close`/
/// `finish`) lives in `CrispASREngineLifecycleTests`.
///
/// Runs on every machine — no dlopen, no model, no Metal: the fake bypasses
/// the library seam and the vad/decode queues are per-engine instance state,
/// so the suite is NOT `.serialized`. Timelines converge through bounded
/// `pollUntilOffMain` polls on the fake's recorded calls and the engine's
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

    /// Reads engine state under its lock — jobs mutate it on their queues.
    private func state<T>(_ engine: CrispASREngine, _ read: () -> T) -> T {
        engine.lock.withLock { read() }
    }

    /// Drains `poll()` until a final appears (bounded); returns it, or nil
    /// on timeout. Asserts the wait succeeded and that no non-final event
    /// (a spurious `.partial`) preceded the final.
    private func pollFinal(_ engine: CrispASREngine) async -> ASREvent? {
        var final: ASREvent?
        var strays: [ASREvent] = []
        let found = await pollUntilOffMain {
            guard let event = engine.poll() else { return false }
            if case .final = event {
                final = event
                return true
            }
            strays.append(event)
            return false
        }
        #expect(found, "a final arrived before the timeout")
        #expect(strays.isEmpty, "no event may precede the final, got \(strays)")
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
        #expect(await pollUntilOffMain { library.transcribeCalls.count == 1 }, "window partial decoded")
        engine.push([Float](repeating: 0, count: 20000)) // 1.25 s clears the 1 s confirmed-silence endpoint

        let final = await pollFinal(engine)
        requireFinal(final, text: "こんにちは。", start: 0, end: 16000)
        #expect(
            library.transcribeCalls.map(\.pcmCount) == [32000, 36000],
            "partial = padded 1 s window, final = the whole 2.25 s utterance"
        )
        #expect(engine.poll() == nil, "the final must be the last event")
    }

    @Test("a decode that is only a non-speech tag finalizes the utterance but emits no final")
    func silenceTagOnlyDecodeEmitsNoFinal() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.spans([(start: 0.0, end: 1.0)])]
        library.transcribeReplies = ["", "<sil>"] // window partial (no event), utterance final = tag only
        let engine = try makePreparedEngine(library)

        engine.push(loudSecond)
        #expect(await pollUntilOffMain { library.transcribeCalls.count == 1 }, "window partial decoded")
        engine.push([Float](repeating: 0, count: 20000)) // 1.25 s clears the 1 s confirmed-silence endpoint

        #expect(await pollUntilOffMain { library.transcribeCalls.count == 2 }, "endpoint final decoded")
        #expect(
            await pollUntilOffMain { state(engine) { engine.utteranceGeneration } == 2 },
            "the tag-only final closed out the utterance — the finalized span is trimmed, the trailing silence seeds the next utterance"
        )
        #expect(engine.poll() == nil, "a `<sil>`-only decode must not become a final")
    }

    @Test("non-speech tags are stripped from a decode that also contains speech")
    func speechDecodeStripsNonSpeechTags() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.spans([(start: 0.0, end: 1.0)])]
        library.transcribeReplies = ["", "こんにちは <sil> です。"]
        let engine = try makePreparedEngine(library)

        engine.push(loudSecond)
        #expect(await pollUntilOffMain { library.transcribeCalls.count == 1 }, "window partial decoded")
        engine.push([Float](repeating: 0, count: 20000))

        let final = await pollFinal(engine)
        requireFinal(final, text: "こんにちは" + "です。", start: 0, end: 16000)
    }

    @Test("a zero-span VAD verdict discards the speechless utterance")
    func speechlessVerdictDiscardsUtterance() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.speechless]
        let engine = try makePreparedEngine(library)

        engine.push([Float](repeating: 0.1, count: 48000)) // 3 s, past the discard floor
        #expect(await pollUntilOffMain { state(engine) { engine.utterance.isEmpty } }, "discard observed")
        #expect(state(engine) { engine.vadAnalyzedThroughSample } == 0, "the discard resets the analysis cursor")

        engine.push(loudSecond)
        #expect(await pollUntilOffMain { library.vadCalls.count == 2 }, "the next utterance's VAD pass ran")

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
            .spans([(start: 0.0, end: 1.5)]), // VAD #1: surplus 0.5 s < endpoint → first partial
            .spans([(start: 0.0, end: 1.5)]), // VAD #2: closed span → endpoint final
            .spans([(start: 0.0, end: 2.75)]) // VAD #3: open span at the buffer end → no endpoint
        ]
        library.transcribeReplies = ["", "ファイナル。", ""]
        let engine = try makePreparedEngine(library)

        engine.push([Float](repeating: 0.1, count: 2 * CrispASREngine.sampleRate))
        #expect(await pollUntilOffMain { library.transcribeCalls.count == 1 }, "first partial decoded")
        engine.push([Float](repeating: 0, count: 20000))
        #expect(await pollUntilOffMain { library.transcribeCalls.count == 2 }, "endpoint final decoded")
        engine.push(loudSecond) // speech resumes on the trimmed window
        #expect(await pollUntilOffMain { library.transcribeCalls.count == 3 }, "post-final partial decoded")

        #expect(library.transcribeCalls.map(\.pcmCount) == [
            32000, // first partial: the 2 s window at the conv floor
            52000, // final: the whole 3.25 s utterance redecode
            40800 // next partial: window minus the finalized span minus the kept tail
        ])
        await requireFinal(pollFinal(engine), text: "ファイナル。", start: 0, end: 24000)
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
        #expect(await pollUntilOffMain { !errors.all.isEmpty }, "the VAD degrade was reported")
        #expect(errors.all == ["VAD failed (-3) — falling back to cap-only finalization"])
        #expect(state(engine) { engine.vadEnabled } == false)

        engine.push([Float](repeating: 0.1, count: 12 * CrispASREngine.sampleRate)) // loud cap
        await requireFinal(pollFinal(engine), text: "キャップ。", start: 0, end: 208_000)
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
            #expect(
                await pollUntilOffMain { state(engine) { engine.consecutiveVADFailures } == failure },
                "VAD failure #\(failure) counted"
            )
        }

        #expect(state(engine) { engine.vadEnabled } == false)
        #expect(errors.all == ["VAD failed (-1) — falling back to cap-only finalization"])
        #expect(library.transcribeCalls.isEmpty)
    }

    @Test("a nil VAD dispatcher reply is skipped without counting a failure")
    func nilVADReplySkippedWithoutFailure() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.unavailable]
        let engine = try makePreparedEngine(library)

        engine.push(loudSecond)
        #expect(
            await pollUntilOffMain {
                !library.vadCalls.isEmpty && state(engine) { engine.vadInFlight } == false
            },
            "the nil reply was delivered and the VAD pass ran to completion"
        )

        #expect(state(engine) { engine.consecutiveVADFailures } == 0)
        #expect(state(engine) { engine.vadInFlight } == false)
        #expect(state(engine) { engine.utteranceGeneration } == 1, "no discard, no final")
        #expect(library.transcribeCalls.isEmpty, "no endpoint was scheduled")
        #expect(engine.poll() == nil)
    }

    @Test("the forced-final cap discards a silent degraded utterance without decoding")
    func silentCapDiscardsWithoutDecode() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.failure(-3)]
        let engine = try makePreparedEngine(library)
        let errors = ErrorRecorder()
        engine.onEngineError = { errors.record($0) }

        engine.push(silentSecond) // VAD #1 → degrade; utterance stays silent
        #expect(await pollUntilOffMain { !errors.all.isEmpty }, "the VAD degrade was reported")

        engine.push([Float](repeating: 0, count: 12 * CrispASREngine.sampleRate)) // silent cap
        #expect(await pollUntilOffMain { state(engine) { engine.utterance.isEmpty } }, "the silent cap discarded the utterance")

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
        #expect(await pollUntilOffMain { !errors.all.isEmpty }, "the VAD degrade was reported")

        let cap = CrispASREngine.utteranceCapSamples
        for push in 0 ..< 32 {
            engine.push([Float](repeating: 0.1, count: cap))
            let expected = library.transcribeCalls.count + 1
            #expect(await pollUntilOffMain { library.transcribeCalls.count >= expected }, "cap decode #\(push + 1) decoded")
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
        #expect(await pollUntilOffMain { library.transcribeCalls.count == 1 }, "the first partial decoded")

        #expect(library.transcribeCalls[0].pcmCount == 2 * CrispASREngine.sampleRate)
        #expect(Array(library.transcribeCalls[0].pcm.prefix(16000)) == loudSecond)
        #expect(
            library.transcribeCalls[0].pcm[16000...].allSatisfy { $0 == 0 },
            "the 1 s window must be zero-padded to the 2 s conv floor"
        )

        engine.push([Float](repeating: 0.1, count: 8000)) // 0.5 s more speech
        #expect(
            await pollUntilOffMain { state(engine) { engine.vadAnalyzedThroughSample } == 24000 },
            "the second VAD pass analyzed the longer utterance"
        )
        #expect(library.transcribeCalls.count == 1, "0.5 s of confirmed new speech is below the cadence")

        engine.push([Float](repeating: 0.1, count: 8000)) // crosses 1 s since the last decode
        #expect(await pollUntilOffMain { library.transcribeCalls.count == 2 }, "the second partial decoded")
        #expect(library.transcribeCalls[1].pcmCount == 32000, "a 2 s window needs no padding")
    }

    @Test("a step-spaced window decode with text posts a .partial event")
    func windowDecodeWithTextPostsPartial() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.spans([(start: 0.0, end: 1.0)])]
        library.transcribeReplies = ["ドラフト。"]
        let engine = try makePreparedEngine(library)

        engine.push(loudSecond)
        #expect(await pollUntilOffMain { library.transcribeCalls.count == 1 }, "partial decode ran")

        var draft: ASREvent?
        #expect(
            await pollUntilOffMain {
                guard let event = engine.poll() else { return false }
                draft = event
                return true
            },
            "the window decode posted a .partial event"
        )
        guard case let .partial(text)? = draft else {
            Issue.record("expected .partial, got \(String(describing: draft))")
            return
        }
        #expect(text == "ドラフト。")
        #expect(engine.poll() == nil, "the partial must be the only event")
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
        #expect(await pollUntilOffMain { library.vadCalls.count == 1 && library.vadEntered }, "VAD #1 dispatched and held inside the fake")

        engine.push([Float](repeating: 0.1, count: 12 * CrispASREngine.sampleRate)) // cap final decode
        // The fake blocks before recording the call, so only entry is
        // observable while held — waiting on the count here would always
        // burn the full timeout.
        #expect(await pollUntilOffMain { library.transcribeEntered }, "the cap decode entered the fake")

        library.transcribeHoldSemaphore?.signal() // the decode closes generation 1
        #expect(await pollUntilOffMain { state(engine) { engine.utteranceGeneration } == 2 }, "the decode closed generation 1")

        library.vadHoldSemaphore?.signal() // VAD #1 resumes into a stale generation
        #expect(await pollUntilOffMain { library.vadFreeCount == 1 }, "the stale VAD result was freed")

        #expect(state(engine) { engine.vadAnalyzedThroughSample } == 0)
        #expect(state(engine) { engine.utteranceHasSpeech } == false)
        #expect(state(engine) { engine.vadLastSpeechEndSample } == nil)
        #expect(state(engine) { engine.utterance.isEmpty })
        await requireFinal(pollFinal(engine), text: "ファイナル。", start: 0, end: 208_000)
    }
}
