@testable import Mimi
import XCTest

/// Tests the public `RomajiAnnotator.segments(for:)` entry point. Expected
/// values are pinned to the system tokenizer's `LatinTranscription` output
/// as verified on macOS 15+.
final class RomajiAnnotatorTests: XCTestCase {

    // MARK: - Fixtures

    private let emptyText = ""
    private let whitespaceText = "   "
    private let greeting = "こんにちは"
    private let expectedGreetingRomaji = "konnichiwa"
    private let eveningGreeting = "こんばんは"
    private let expectedEveningRomaji = "konbanwa"
    private let cherry = "桜"
    private let expectedCherryFurigana = "さくら"
    private let numberCounter = "一回"
    private let expectedNumberCounterRomaji = "ikkai"
    private let digitCounter = "600回"
    private let expectedDigitCounterRomaji = "roppyakkai"
    private let geminatingKanjiNumber = "八歳"
    private let expectedGeminatingRomaji = "hassai"
    private let latinWord = "Hello"
    private let digits = "123"
    private let weatherSentence = "今日はいい天気ですね。"
    private let expectedWeatherSurfaces = ["今日", "は", "いい", "天気", "です", "ね", "。"]
    private let particleSentence = "動画を見ます。"
    private let particleSurface = "を"
    private let expectedParticleRomaji = "o"

    // MARK: - Helpers

    private func firstSegment(of text: String) -> RomajiSegment? {
        RomajiAnnotator.segments(for: text)?.first
    }

    // MARK: - Empty input

    func test_segments_whenTextIsEmpty_shouldReturnNil() {
        let result = RomajiAnnotator.segments(for: emptyText)

        XCTAssertNil(result)
    }

    func test_segments_whenTextIsWhitespaceOnly_shouldReturnNil() {
        let result = RomajiAnnotator.segments(for: whitespaceText)

        XCTAssertNil(result)
    }

    // MARK: - Romaji transcription

    func test_segments_whenLexicalOverrideSurface_shouldTranscribeKonnichiwa() {
        let segment = firstSegment(of: greeting)

        XCTAssertEqual(segment?.romaji, expectedGreetingRomaji)
    }

    func test_segments_whenEveningGreeting_shouldTranscribeKonbanwa() {
        let segment = firstSegment(of: eveningGreeting)

        XCTAssertEqual(segment?.romaji, expectedEveningRomaji)
    }

    func test_segments_whenParticleSurface_shouldRomanizeTopicParticle() {
        let segments = RomajiAnnotator.segments(for: particleSentence)
        let particle = segments?.first { $0.surface == particleSurface }

        let romaji = particle?.romaji

        XCTAssertEqual(romaji, expectedParticleRomaji)
    }

    func test_segments_whenPunctuatedSentence_shouldSplitIntoWordRuns() {
        let segments = RomajiAnnotator.segments(for: weatherSentence)
        let surfaces = segments?.map(\.surface)

        XCTAssertEqual(surfaces, expectedWeatherSurfaces)
    }

    // MARK: - Furigana

    func test_segments_whenKanjiSurface_shouldProvideKanaFurigana() {
        let segment = firstSegment(of: cherry)

        XCTAssertEqual(segment?.furigana, expectedCherryFurigana)
    }

    func test_segments_whenKanaOnlySurface_shouldLeaveFuriganaNil() {
        let segment = firstSegment(of: greeting)

        XCTAssertNil(segment?.furigana)
    }

    func test_segments_whenDigitSurface_shouldLeaveFuriganaNil() {
        let segment = firstSegment(of: digits)

        XCTAssertNil(segment?.furigana)
    }

    // MARK: - Number + counter fusion

    func test_segments_whenNumberFusesWithCounter_shouldEmitSingleFusedSegment() {
        let segments = RomajiAnnotator.segments(for: numberCounter)

        let surface = segments?.first?.surface

        XCTAssertEqual(surface, numberCounter)
    }

    func test_segments_whenNumberFusesWithCounter_shouldGeminate() {
        let segment = firstSegment(of: numberCounter)

        XCTAssertEqual(segment?.romaji, expectedNumberCounterRomaji)
    }

    func test_segments_whenDigitCounterFuses_shouldGeminate() {
        let segment = firstSegment(of: digitCounter)

        XCTAssertEqual(segment?.romaji, expectedDigitCounterRomaji)
    }

    func test_segments_whenKanjiNumberGeminatesBeforeCounter_shouldFuse() {
        let segment = firstSegment(of: geminatingKanjiNumber)

        XCTAssertEqual(segment?.romaji, expectedGeminatingRomaji)
    }

    // MARK: - Self-transcribed runs

    func test_segments_whenLatinSurface_shouldSelfTranscribe() {
        let segment = firstSegment(of: latinWord)

        XCTAssertEqual(segment?.romaji, latinWord)
    }

    func test_segments_whenPunctuationRun_shouldLeaveRomajiNil() {
        let segments = RomajiAnnotator.segments(for: weatherSentence)
        let punctuation = segments?.last

        let romaji = punctuation?.romaji

        XCTAssertNil(romaji)
    }
}
