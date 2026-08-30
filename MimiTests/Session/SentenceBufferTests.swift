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
    /// 50 chars, no clause boundary anywhere; the length cap cannot split.
    private let boundarylessOverCapText = String(repeating: "あ", count: 50)
    /// 43 chars; ASCII `,` at index 40 (past `minSplitChars` = 18).
    private let asciiCommaSplitText = String(repeating: "あ", count: 40) + ",です"
    private let expectedAsciiCommaSplitHead = String(repeating: "あ", count: 40) + ","
    /// 42 chars; the split tail is the single symbol `、` (no content), which
    /// close() must drop silently.
    private let symbolOnlyTailSplitText = String(repeating: "あ", count: 40) + "、、"
    private let expectedSymbolOnlyTailHead = String(repeating: "あ", count: 40) + "、"
    /// 45 chars ending in a terminal `。`: tier 1 closes the whole buffer, so
    /// the length-cap split never runs on terminal-tailed input.
    private let terminalTailedOverCapText =
        "今日はとても良い天気なので散歩に行きました、そのあとは買い物に出かけて晩ご飯を食べました。"
    private let asciiQuestionSentence = "Is this new?"
    private let asciiExclamationSentence = "Nice!"

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

    func test_append_beyondLengthCap_whenNoClauseBoundary_shouldKeepBufferGrowing() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: boundarylessOverCapText, startSample: 0, endSample: oneSecondInSamples
        )
        buffer.append(
            finalText: "いいね", startSample: oneSecondInSamples, endSample: twoSecondsInSamples
        )

        XCTAssertEqual(sink.sentences.count, 0)

        buffer.flush()

        XCTAssertEqual(sink.sentences.count, 1)
        XCTAssertEqual(sink.sentences.first?.text, boundarylessOverCapText + "いいね")
    }

    func test_append_whenTerminalPunctuationExceedsLengthCap_shouldCloseWholeBufferWithoutSplit() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: terminalTailedOverCapText, startSample: 0, endSample: oneSecondInSamples
        )

        XCTAssertEqual(sink.sentences.count, 1)
        XCTAssertEqual(sink.sentences.first?.text, terminalTailedOverCapText)
    }

    func test_append_beyondLengthCap_shouldSplitAtAsciiCommaBoundary() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: asciiCommaSplitText, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        XCTAssertEqual(sink.sentences.count, 1)
        XCTAssertEqual(sink.sentences.first?.text, expectedAsciiCommaSplitHead)
    }

    func test_append_whenSplitTailIsSymbolOnly_shouldDropTailSilentlyOnFlush() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: symbolOnlyTailSplitText, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )
        XCTAssertEqual(sink.sentences.count, 1)
        XCTAssertEqual(sink.sentences.first?.text, expectedSymbolOnlyTailHead)

        buffer.flush()

        XCTAssertEqual(sink.sentences.count, 1)
        XCTAssertEqual(buffer.nextIndex, 1)
    }

    func test_append_whenTerminalPunctuationFollowsClauseSplit_shouldCloseReinstatedTail() {
        let (buffer, sink) = makeSUT()
        buffer.append(
            finalText: asciiCommaSplitText, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        buffer.append(
            finalText: "。", startSample: fourSecondsInSamples, endSample: fourSecondsInSamples
        )

        XCTAssertEqual(sink.sentences.map(\.text), [expectedAsciiCommaSplitHead, "です。"])
    }

    func test_append_acrossClauseSplitsFlushesAndAppends_shouldKeepIndicesContinuous() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: longClauseSentence, startSample: 0, endSample: oneSecondInSamples
        )
        buffer.flush()
        buffer.append(
            finalText: punctuatedSentence, startSample: oneSecondInSamples,
            endSample: twoSecondsInSamples
        )

        XCTAssertEqual(sink.sentences.map(\.index), [0, 1, 2])
    }

    // MARK: - ASCII terminals

    func test_append_whenAsciiQuestionMarkTerminal_shouldCloseImmediately() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: asciiQuestionSentence, startSample: 0, endSample: oneSecondInSamples
        )

        XCTAssertEqual(sink.sentences.count, 1)
        XCTAssertEqual(sink.sentences.first?.text, asciiQuestionSentence)
    }

    func test_append_whenAsciiExclamationTerminal_shouldCloseImmediately() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: asciiExclamationSentence, startSample: 0, endSample: oneSecondInSamples
        )

        XCTAssertEqual(sink.sentences.count, 1)
        XCTAssertEqual(sink.sentences.first?.text, asciiExclamationSentence)
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
