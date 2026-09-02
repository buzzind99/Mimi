@testable import Mimi
import Testing

/// Tests `MockASREngine`'s pure-Swift pipeline: the RMS speech threshold,
/// the randomized sentence cadence (`nextSentenceAt`), the single-slot poll
/// FIFO, sample accounting, and the always-empty finish drain.
@Suite("MockASREngine")
struct MockASREngineTests {

    // MARK: - Fixtures

    private let engine = MockASREngine()

    /// Constant-amplitude chunk: its RMS equals the amplitude, so 0.01 is
    /// speech (≫ 1e-3 threshold) and 0.0005 is silence (< 1e-3).
    private func pushSpeech(_ samples: Int = 1000) {
        engine.push([Float](repeating: 0.01, count: samples))
    }

    private func pushSilence(_ samples: Int = 1000) {
        engine.push([Float](repeating: 0, count: samples))
    }

    private struct MissingFinal: Error {}

    private struct EmittedFinal {
        let text: String
        let startSample: Int
        let endSample: Int
        let lang: String
    }

    /// Drains one `.final` out of the engine, asserting its shape.
    private func pollFinal() throws -> EmittedFinal {
        let event = try #require(engine.poll(), "expected a final event")
        guard case let .final(text, start, end, lang) = event else {
            Issue.record("expected a .final event, got \(event)")
            throw MissingFinal()
        }
        return EmittedFinal(text: text, startSample: start, endSample: end, lang: lang)
    }

    // MARK: - prepare / openStream

    @Test("prepare and openStream are no-throw no-ops")
    func prepareAndOpenStream() throws {
        try engine.prepare()
        try engine.openStream()

        #expect(engine.processedSamples == 0)
        #expect(engine.poll() == nil)
    }

    // MARK: - isMock / processedSamples

    @Test("reports itself as the mock engine")
    func isMockIsTrue() {
        #expect(engine.isMock)
    }

    @Test("processedSamples is zero before anything is pushed")
    func processedSamplesStartAtZero() {
        #expect(engine.processedSamples == 0)
    }

    @Test("push accumulates silence and speech samples")
    func pushAccumulatesSamples() {
        pushSilence(500)
        pushSilence(500)
        pushSpeech(200)
        engine.push([])

        #expect(engine.processedSamples == 1200)
    }

    // MARK: - RMS speech threshold

    @Test("silence-only audio never produces sentences")
    func silenceNeverProducesSentences() {
        for _ in 0 ..< 100 {
            pushSilence()
            #expect(engine.poll() == nil)
        }

        #expect(engine.poll() == nil)
        #expect(engine.processedSamples == 100_000)
    }

    @Test("chunks with an RMS below the speech threshold do not count as speech")
    func rmsBelowThresholdIsNotSpeech() {
        // 0.0005 constant amplitude → RMS 0.0005 < 1e-3: even 100 chunks of
        // it never reach the initial cadence of 6 speech chunks.
        for _ in 0 ..< 100 {
            engine.push([Float](repeating: 0.0005, count: 1000))
        }

        #expect(engine.poll() == nil)
    }

    @Test("chunks with an RMS above the speech threshold count as speech")
    func rmsAboveThresholdIsSpeech() {
        // 0.01 constant amplitude → RMS 0.01 > 1e-3: the 6th chunk crosses
        // the initial cadence and produces a sentence.
        for _ in 0 ..< 6 {
            pushSpeech()
        }

        #expect(engine.poll() != nil)
    }

    // MARK: - Sentence cadence (nextSentenceAt)

    @Test("fewer speech chunks than the cadence stays silent")
    func cadenceBelowThresholdStaysSilent() {
        // Initial cadence is 6 speech chunks; 5 stay silent (including a
        // mixed-in silent chunk that must not advance the counter).
        for _ in 0 ..< 4 {
            pushSpeech()
        }
        pushSilence()
        pushSpeech()

        #expect(engine.poll() == nil)
    }

    @Test("reaching the cadence emits a final with the canned text")
    func cadenceReachedEmitsFinal() throws {
        for _ in 0 ..< 5 {
            pushSpeech()
            #expect(engine.poll() == nil, "no final before the cadence is reached")
        }
        pushSpeech()

        let final = try pollFinal()

        #expect(final.text == "今日はいい天気ですね。")
        #expect(final.lang == "ja")
        #expect(final.startSample == 0)
        #expect(final.endSample == engine.processedSamples)
    }

    @Test("the second sentence lands within the random cadence window")
    func secondSentenceWithinRandomWindow() throws {
        // The next cadence lands 5–12 speech chunks after the first final;
        // 18 pushes guarantee it regardless of the draw.
        for _ in 0 ..< 6 {
            pushSpeech()
        }
        let first = try pollFinal()

        for _ in 0 ..< 18 {
            pushSpeech()
        }
        let second = try pollFinal()

        #expect(second.text == "これから配信を始めます、よろしくお願いします。")
        #expect(second.startSample == first.endSample)
        #expect(second.endSample == engine.processedSamples)
    }

    // MARK: - poll FIFO + nil-when-empty

    @Test("a drained final is not redelivered")
    func pollDrainsExactlyOnce() {
        for _ in 0 ..< 6 {
            pushSpeech()
        }
        #expect(engine.poll() != nil)

        #expect(engine.poll() == nil, "single slot: drained finals are not redelivered")
    }

    @Test("repeated polls before the cadence return nil each time")
    func pollBeforeCadenceReturnsNil() {
        pushSpeech()

        #expect(engine.poll() == nil)
        #expect(engine.poll() == nil)
    }

    @Test("sentences deliver the canned texts in rotation order")
    func cannedTextsDeliverInRotation() {
        // 6 sentences wrap the canned list (index % count); each cadence
        // needs at most 12 speech chunks, so 200 pushes always suffice.
        let canned = [
            "今日はいい天気ですね。",
            "これから配信を始めます、よろしくお願いします。",
            "新しいゲーム、みんな遊んだ？",
            "チャットの質問に答えていきますね。",
            "次の話題に移ります、面白いですよ。"
        ]
        var texts: [String] = []
        var pushes = 0
        while texts.count < 6, pushes < 200 {
            pushSpeech()
            pushes += 1
            if case let .final(text, _, _, _)? = engine.poll() {
                texts.append(text)
            }
        }

        #expect(texts == canned + [canned[0]], "canned texts delivered in rotation order")
    }

    // MARK: - finish

    @Test("finish with nothing pending returns no events")
    func finishWithoutPendingReturnsNoEvents() {
        pushSilence()

        #expect(engine.finish().isEmpty)
    }

    @Test("finish never flushes a pending final")
    func finishDropsPendingFinal() {
        for _ in 0 ..< 6 {
            pushSpeech()
        }
        #expect(engine.poll() != nil) // first cadence drained

        for _ in 0 ..< 18 {
            pushSpeech()
        }

        // The mock never flushes its pending final on finish — the drain is
        // always empty (session teardown drops the tail).
        #expect(engine.finish().isEmpty)
    }
}
