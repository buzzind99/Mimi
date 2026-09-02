import Foundation
@testable import Mimi
import Testing

/// Tests the 3-tier sentence boundary policy through the public
/// `append` / `tick` / `flush` API, capturing emitted `Sentence` values.
@Suite("SentenceBuffer boundary policy")
struct SentenceBufferTests {

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

    @Test("terminal punctuation emits a sentence immediately")
    func terminalPunctuationEmitsImmediately() {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: punctuatedSentence, startSample: 0, endSample: oneSecondInSamples)

        #expect(sink.sentences.count == 1)
    }

    @Test("terminal punctuation emits the full text")
    func terminalPunctuationEmitsFullText() {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: punctuatedSentence, startSample: 0, endSample: oneSecondInSamples)

        #expect(sink.sentences.first?.text == punctuatedSentence)
    }

    @Test("terminal punctuation records the start timestamp")
    func terminalPunctuationRecordsStartTimestamp() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: punctuatedSentence, startSample: oneSecondInSamples,
            endSample: twoSecondsInSamples
        )

        #expect(sink.sentences.first?.startS == 1.0)
    }

    @Test("terminal punctuation records the end timestamp")
    func terminalPunctuationRecordsEndTimestamp() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: punctuatedSentence, startSample: oneSecondInSamples,
            endSample: twoSecondsInSamples
        )

        #expect(sink.sentences.first?.endS == 2.0)
    }

    @Test("multiple emitted sentences increment the index")
    func multipleSentencesIncrementIndex() {
        let (buffer, sink) = makeSUT()
        buffer.append(finalText: punctuatedSentence, startSample: 0, endSample: oneSecondInSamples)

        buffer.append(
            finalText: punctuatedSentence, startSample: oneSecondInSamples,
            endSample: twoSecondsInSamples
        )

        #expect(sink.sentences.last?.index == 1)
    }

    // MARK: - Symbol-only finals

    @Test("a symbol-only final with an empty buffer is not emitted")
    func symbolOnlyFinalWithEmptyBufferNotEmitted() {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: symbolOnlyFinal, startSample: 0, endSample: oneSecondInSamples)

        #expect(sink.sentences.count == 0)
    }

    @Test("a symbol-only final after content stays as trailing punctuation")
    func symbolOnlyFinalAfterContentStaysTrailing() {
        let (buffer, sink) = makeSUT()
        buffer.append(finalText: contentFinal, startSample: 0, endSample: oneSecondInSamples)
        buffer.append(finalText: symbolOnlyFinal, startSample: oneSecondInSamples, endSample: oneSecondInSamples)

        buffer.flush()

        #expect(sink.sentences.first?.text == contentFinal + symbolOnlyFinal)
    }

    // MARK: - Tier 2: silence timeout

    @Test("tick after the silence timeout closes the sentence")
    func tickAfterSilenceTimeoutCloses() {
        let (buffer, sink) = makeSUT()
        buffer.append(finalText: unpunctuatedSentence, startSample: 0, endSample: oneSecondInSamples)

        buffer.tick(now: .now.advanced(by: .seconds(2)))

        #expect(sink.sentences.first?.text == unpunctuatedSentence)
    }

    @Test("tick before the silence timeout keeps the buffer open")
    func tickBeforeSilenceTimeoutKeepsOpen() {
        let (buffer, sink) = makeSUT()
        buffer.append(finalText: unpunctuatedSentence, startSample: 0, endSample: oneSecondInSamples)

        buffer.tick(now: .now)

        #expect(sink.sentences.count == 0)
    }

    @Test("tick with an empty buffer emits nothing")
    func tickWithEmptyBufferNotEmitted() {
        let (buffer, sink) = makeSUT()

        buffer.tick(now: .now.advanced(by: .seconds(60)))

        #expect(sink.sentences.count == 0)
    }

    // MARK: - Tier 3: length cap

    @Test("beyond the length cap the buffer splits at the clause boundary")
    func overCapSplitsAtClauseBoundary() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: longClauseSentence, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        #expect(sink.sentences.first?.text == expectedSplitHead)
    }

    @Test("beyond the length cap the split head records its start timestamp")
    func overCapRecordsHeadStartTimestamp() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: longClauseSentence, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        #expect(sink.sentences.first?.startS == 2.0)
    }

    @Test("flush after a clause split emits the tail")
    func flushAfterClauseSplitEmitsTail() {
        let (buffer, sink) = makeSUT()
        buffer.append(
            finalText: longClauseSentence, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        buffer.flush()

        #expect(sink.sentences.last?.text == expectedSplitTail)
    }

    @Test("flush after a clause split records the tail start timestamp")
    func flushAfterClauseSplitRecordsTailTimestamp() {
        let (buffer, sink) = makeSUT()
        buffer.append(
            finalText: longClauseSentence, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        buffer.flush()

        #expect(sink.sentences.last?.startS == 4.0)
    }

    @Test("beyond the length cap with no clause boundary the buffer keeps growing")
    func overCapWithoutBoundaryKeepsGrowing() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: boundarylessOverCapText, startSample: 0, endSample: oneSecondInSamples
        )
        buffer.append(
            finalText: "いいね", startSample: oneSecondInSamples, endSample: twoSecondsInSamples
        )

        #expect(sink.sentences.count == 0)

        buffer.flush()

        #expect(sink.sentences.count == 1)
        #expect(sink.sentences.first?.text == boundarylessOverCapText + "いいね")
    }

    @Test("terminal punctuation beyond the length cap closes the whole buffer without splitting")
    func terminalTailedOverCapClosesWholeBuffer() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: terminalTailedOverCapText, startSample: 0, endSample: oneSecondInSamples
        )

        #expect(sink.sentences.count == 1)
        #expect(sink.sentences.first?.text == terminalTailedOverCapText)
    }

    @Test("beyond the length cap the buffer splits at an ASCII comma boundary")
    func overCapSplitsAtAsciiComma() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: asciiCommaSplitText, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        #expect(sink.sentences.count == 1)
        #expect(sink.sentences.first?.text == expectedAsciiCommaSplitHead)
    }

    @Test("a symbol-only split tail is dropped silently on flush")
    func symbolOnlyTailDroppedOnFlush() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: symbolOnlyTailSplitText, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )
        #expect(sink.sentences.count == 1)
        #expect(sink.sentences.first?.text == expectedSymbolOnlyTailHead)

        buffer.flush()

        #expect(sink.sentences.count == 1)
        #expect(buffer.nextIndex == 1)
    }

    @Test("terminal punctuation after a clause split closes the reinstated tail")
    func terminalAfterClauseSplitClosesTail() {
        let (buffer, sink) = makeSUT()
        buffer.append(
            finalText: asciiCommaSplitText, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        buffer.append(
            finalText: "。", startSample: fourSecondsInSamples, endSample: fourSecondsInSamples
        )

        #expect(sink.sentences.map(\.text) == [expectedAsciiCommaSplitHead, "です。"])
    }

    @Test("indices stay continuous across clause splits, flushes, and appends")
    func indicesContinuousAcrossSplitsFlushesAndAppends() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: longClauseSentence, startSample: 0, endSample: oneSecondInSamples
        )
        buffer.flush()
        buffer.append(
            finalText: punctuatedSentence, startSample: oneSecondInSamples,
            endSample: twoSecondsInSamples
        )

        #expect(sink.sentences.map(\.index) == [0, 1, 2])
    }

    // MARK: - ASCII terminals

    @Test("an ASCII question mark terminal closes immediately")
    func asciiQuestionTerminalClosesImmediately() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: asciiQuestionSentence, startSample: 0, endSample: oneSecondInSamples
        )

        #expect(sink.sentences.count == 1)
        #expect(sink.sentences.first?.text == asciiQuestionSentence)
    }

    @Test("an ASCII exclamation terminal closes immediately")
    func asciiExclamationTerminalClosesImmediately() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: asciiExclamationSentence, startSample: 0, endSample: oneSecondInSamples
        )

        #expect(sink.sentences.count == 1)
        #expect(sink.sentences.first?.text == asciiExclamationSentence)
    }

    // MARK: - Flush

    @Test("flush emits a partial buffer")
    func flushEmitsPartialBuffer() {
        let (buffer, sink) = makeSUT()
        buffer.append(finalText: unpunctuatedSentence, startSample: 0, endSample: oneSecondInSamples)

        buffer.flush()

        #expect(sink.sentences.first?.text == unpunctuatedSentence)
    }

    @Test("flush with an empty buffer emits nothing")
    func flushWithEmptyBufferNotEmitted() {
        let (buffer, sink) = makeSUT()

        buffer.flush()

        #expect(sink.sentences.count == 0)
    }
}
