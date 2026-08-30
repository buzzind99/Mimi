@testable import Mimi
import XCTest

/// Tests `MockASREngine`'s pure-Swift pipeline: the RMS speech threshold,
/// the randomized sentence cadence (`nextSentenceAt`), the single-slot poll
/// FIFO, sample accounting, and the always-empty finish drain.
final class MockASREngineTests: XCTestCase {

    // MARK: - Fixtures

    private var engine: MockASREngine!

    override func setUp() {
        super.setUp()
        engine = MockASREngine()
    }

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
        guard case let .final(text, start, end, lang)? = engine.poll() else {
            XCTFail("expected a final event")
            throw MissingFinal()
        }
        return EmittedFinal(
            text: text, startSample: start, endSample: end, lang: lang
        )
    }

    // MARK: - prepare / openStream

    func test_prepare_andOpenStream_shouldBeNoThrowNoOps() {
        XCTAssertNoThrow(try engine.prepare())
        XCTAssertNoThrow(try engine.openStream())

        XCTAssertEqual(engine.processedSamples, 0)
        XCTAssertNil(engine.poll())
    }

    // MARK: - isMock / processedSamples

    func test_isMock_shouldBeTrue() {
        XCTAssertTrue(engine.isMock)
    }

    func test_processedSamples_whenNothingPushed_shouldBeZero() {
        XCTAssertEqual(engine.processedSamples, 0)
    }

    func test_push_shouldAccumulateSilenceAndSpeechSamples() {
        pushSilence(500)
        pushSilence(500)
        pushSpeech(200)
        engine.push([])

        XCTAssertEqual(engine.processedSamples, 1200)
    }

    // MARK: - RMS speech threshold

    func test_push_whenSilenceOnly_shouldNeverProduceSentences() {
        for _ in 0 ..< 100 {
            pushSilence()
            XCTAssertNil(engine.poll())
        }

        XCTAssertNil(engine.poll())
        XCTAssertEqual(engine.processedSamples, 100_000)
    }

    func test_push_whenRMSBelowThreshold_shouldNotCountAsSpeech() {
        // 0.0005 constant amplitude → RMS 0.0005 < 1e-3: even 100 chunks of
        // it never reach the initial cadence of 6 speech chunks.
        for _ in 0 ..< 100 {
            engine.push([Float](repeating: 0.0005, count: 1000))
        }

        XCTAssertNil(engine.poll())
    }

    func test_push_whenRMSAboveThreshold_shouldCountAsSpeech() {
        // 0.01 constant amplitude → RMS 0.01 > 1e-3: the 6th chunk crosses
        // the initial cadence and produces a sentence.
        for _ in 0 ..< 6 {
            pushSpeech()
        }

        XCTAssertNotNil(engine.poll())
    }

    // MARK: - Sentence cadence (nextSentenceAt)

    func test_cadence_whenFewerSpeechChunksThanNextSentenceAt_shouldStaySilent() {
        // Initial cadence is 6 speech chunks; 5 stay silent (including a
        // mixed-in silent chunk that must not advance the counter).
        for _ in 0 ..< 4 {
            pushSpeech()
        }
        pushSilence()
        pushSpeech()

        XCTAssertNil(engine.poll())
    }

    func test_cadence_whenSpeechChunksReachNextSentenceAt_shouldEmitFinal() throws {
        for _ in 0 ..< 5 {
            pushSpeech()
            XCTAssertNil(engine.poll(), "no final before the cadence is reached")
        }
        pushSpeech()

        let final = try pollFinal()
        XCTAssertEqual(final.text, "今日はいい天気ですね。")
        XCTAssertEqual(final.lang, "ja")
        XCTAssertEqual(final.startSample, 0)
        XCTAssertEqual(final.endSample, engine.processedSamples)
    }

    func test_cadence_afterFirstSentence_shouldEmitSecondWithinRandomWindow() throws {
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

        XCTAssertEqual(second.text, "これから配信を始めます、よろしくお願いします。")
        XCTAssertEqual(second.startSample, first.endSample)
        XCTAssertEqual(second.endSample, engine.processedSamples)
    }

    // MARK: - poll FIFO + nil-when-empty

    func test_poll_whenPending_shouldDrainExactlyOnce() {
        for _ in 0 ..< 6 {
            pushSpeech()
        }
        XCTAssertNotNil(engine.poll())

        XCTAssertNil(engine.poll(), "single slot: drained finals are not redelivered")
    }

    func test_poll_whenCalledRepeatedlyBeforeCadence_shouldReturnNilEachTime() {
        pushSpeech()
        XCTAssertNil(engine.poll())
        XCTAssertNil(engine.poll())
    }

    func test_poll_acrossSentences_shouldDeliverCannedTextsInOrder() {
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

        XCTAssertEqual(texts, canned + [canned[0]], "canned texts delivered in rotation order")
    }

    // MARK: - finish

    func test_finish_whenNothingPending_shouldReturnNoEvents() {
        pushSilence()

        XCTAssertTrue(engine.finish().isEmpty)
    }

    func test_finish_withAPendingFinal_shouldStillReturnNoEvents() {
        for _ in 0 ..< 6 {
            pushSpeech()
        }
        XCTAssertNotNil(engine.poll()) // first cadence drained

        for _ in 0 ..< 18 {
            pushSpeech()
        }

        // The mock never flushes its pending final on finish — the drain is
        // always empty (session teardown drops the tail).
        XCTAssertTrue(engine.finish().isEmpty)
    }
}
