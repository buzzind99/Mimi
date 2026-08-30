@testable import Mimi
import XCTest

/// Tests the 3-tier sentence boundary policy through the public
/// `append` / `tick` / `flush` API, capturing emitted `Sentence` values.
final class SentenceBufferTests: XCTestCase {

    // MARK: - Fixtures

    private let punctuatedSentence = "今日はいい天気ですね。"
    private let unpunctuatedSentence = "今日はいい天気ですね"
    private let symbolOnlyFinal = "..."
    private let contentFinal = "今日は"
    /// 44 chars, no terminal punctuation; clause boundary `、` at index 23
    /// (past `minSplitChars` = 18), so the length cap splits there.
    private let longClauseSentence =
        "今日はとても良い天気なので散歩に行きました、そのあとに買い物に出かけて晩ご飯を食べました"
    private let expectedSplitHead = "今日はとても良い天気なので散歩に行きました、"
    private let expectedSplitTail = "そのあとに買い物に出かけて晩ご飯を食べました"
    private let oneSecondInSamples = 16000
    private let twoSecondsInSamples = 32000
    private let fourSecondsInSamples = 64000

    // MARK: - Helpers

    /// Captures emitted sentences so each test asserts on real outputs.
    private final class SentenceSink {
        private(set) var sentences: [Sentence] = []

        func receive(_ sentence: Sentence) {
            sentences.append(sentence)
        }
    }

    private func makeSUT() -> (buffer: SentenceBuffer, sink: SentenceSink) {
        let sink = SentenceSink()
        let buffer = SentenceBuffer()
        buffer.onSentence = { sink.receive($0) }
        return (buffer, sink)
    }

    // MARK: - Tier 1: terminal punctuation

    func test_append_whenTerminalPunctuation_shouldEmitSentenceImmediately() {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: punctuatedSentence, startSample: 0, endSample: oneSecondInSamples)

        XCTAssertEqual(sink.sentences.count, 1)
    }

    func test_append_whenTerminalPunctuation_shouldEmitFullText() {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: punctuatedSentence, startSample: 0, endSample: oneSecondInSamples)

        XCTAssertEqual(sink.sentences.first?.text, punctuatedSentence)
    }

    func test_append_whenTerminalPunctuation_shouldRecordStartTimestamp() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: punctuatedSentence, startSample: oneSecondInSamples,
            endSample: twoSecondsInSamples
        )

        XCTAssertEqual(sink.sentences.first?.startS, 1.0)
    }

    func test_append_whenTerminalPunctuation_shouldRecordEndTimestamp() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: punctuatedSentence, startSample: oneSecondInSamples,
            endSample: twoSecondsInSamples
        )

        XCTAssertEqual(sink.sentences.first?.endS, 2.0)
    }

    func test_append_whenMultipleSentencesEmitted_shouldIncrementIndex() {
        let (buffer, sink) = makeSUT()
        buffer.append(finalText: punctuatedSentence, startSample: 0, endSample: oneSecondInSamples)

        buffer.append(
            finalText: punctuatedSentence, startSample: oneSecondInSamples,
            endSample: twoSecondsInSamples
        )

        XCTAssertEqual(sink.sentences.last?.index, 1)
    }

    // MARK: - Symbol-only finals

    func test_append_whenSymbolOnlyFinalAndBufferEmpty_shouldNotEmit() {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: symbolOnlyFinal, startSample: 0, endSample: oneSecondInSamples)

        XCTAssertEqual(sink.sentences.count, 0)
    }

    func test_append_whenSymbolOnlyFinalAfterContent_shouldKeepAsTrailing() {
        let (buffer, sink) = makeSUT()
        buffer.append(finalText: contentFinal, startSample: 0, endSample: oneSecondInSamples)
        buffer.append(finalText: symbolOnlyFinal, startSample: oneSecondInSamples, endSample: oneSecondInSamples)

        buffer.flush()

        XCTAssertEqual(sink.sentences.first?.text, contentFinal + symbolOnlyFinal)
    }

    // MARK: - Tier 2: silence timeout

    func test_tick_afterSilenceTimeout_shouldCloseSentence() {
        let (buffer, sink) = makeSUT()
        buffer.append(finalText: unpunctuatedSentence, startSample: 0, endSample: oneSecondInSamples)

        buffer.tick(now: Date().addingTimeInterval(2))

        XCTAssertEqual(sink.sentences.first?.text, unpunctuatedSentence)
    }

    func test_tick_beforeSilenceTimeout_shouldKeepBufferOpen() {
        let (buffer, sink) = makeSUT()
        buffer.append(finalText: unpunctuatedSentence, startSample: 0, endSample: oneSecondInSamples)

        buffer.tick(now: Date())

        XCTAssertEqual(sink.sentences.count, 0)
    }

    func test_tick_whenBufferEmpty_shouldNotEmit() {
        let (buffer, sink) = makeSUT()

        buffer.tick(now: Date().addingTimeInterval(60))

        XCTAssertEqual(sink.sentences.count, 0)
    }

    // MARK: - Tier 3: length cap

    func test_append_beyondLengthCap_shouldSplitAtClauseBoundary() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: longClauseSentence, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        XCTAssertEqual(sink.sentences.first?.text, expectedSplitHead)
    }

    func test_append_beyondLengthCap_shouldRecordHeadStartTimestamp() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: longClauseSentence, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        XCTAssertEqual(sink.sentences.first?.startS, 2.0)
    }

    func test_flush_afterClauseSplit_shouldEmitTail() {
        let (buffer, sink) = makeSUT()
        buffer.append(
            finalText: longClauseSentence, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        buffer.flush()

        XCTAssertEqual(sink.sentences.last?.text, expectedSplitTail)
    }

    func test_flush_afterClauseSplit_shouldRecordTailStartTimestamp() {
        let (buffer, sink) = makeSUT()
        buffer.append(
            finalText: longClauseSentence, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        buffer.flush()

        XCTAssertEqual(sink.sentences.last?.startS, 4.0)
    }

    // MARK: - Flush

    func test_flush_whenBufferHasPartialSentence_shouldEmit() {
        let (buffer, sink) = makeSUT()
        buffer.append(finalText: unpunctuatedSentence, startSample: 0, endSample: oneSecondInSamples)

        buffer.flush()

        XCTAssertEqual(sink.sentences.first?.text, unpunctuatedSentence)
    }

    func test_flush_whenBufferEmpty_shouldNotEmit() {
        let (buffer, sink) = makeSUT()

        buffer.flush()

        XCTAssertEqual(sink.sentences.count, 0)
    }
}
