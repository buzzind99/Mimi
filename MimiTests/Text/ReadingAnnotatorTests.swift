@testable import Mimi
import XCTest

/// Tests the public `ReadingAnnotator.segments(for:)` entry point. Expected
/// values are pinned to the system tokenizer's `LatinTranscription` output
/// as verified on macOS 15+.
final class ReadingAnnotatorTests: XCTestCase {

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
    private let latinSentence = "A B"
    private let sokuonFusionSentence = "言ってあげる"
    private let expectedSokuonFusionSurface = "言って"
    private let expectedSokuonFusionRomaji = "itte"
    private let expectedSokuonFusionFurigana = "いって"
    private let tsuFallbackSentence = "おっ、いいね"
    private let expectedTsuFallbackRomaji = "otsu"
    private let trailingSokuonSentence = "そう言っ"
    private let expectedTrailingSokuonRomaji = "itsu"
    private let rareIdeographSentence = "𠮷野家"
    private let extAIdeograph = "㐂"
    private let repeatedKanjiWord = "時々"
    private let expectedRepeatedKanjiFurigana = "ときどき"
    private let directionalParticle = "学校へ行く"
    private let expectedDirectionalParticleRomaji = "e"
    private let plainHonSentence = "二本"
    private let expectedPlainHonReading = "hon"
    private let voicedHonSentence = "三万本"
    private let expectedVoicedHonReading = "bon"
    private let dateCounterWord = "二日"
    private let expectedDateCounterRomaji = "futsuka"
    private let sokuonDateCounterWord = "三日"
    private let expectedSokuonDateCounterRomaji = "mikka"
    private let multiCharDateCounterWord = "二十日"
    private let expectedMultiCharDateCounterRomaji = "hatsuka"
    private let datePairOverrideWord = "四日"
    private let expectedDatePairOverrideRomaji = "yokka"
    private let secondDatePairOverrideWord = "七日"
    private let expectedSecondDatePairOverrideRomaji = "nanoka"
    private let rokuExceptionWord = "六歳"
    private let expectedRokuExceptionSegments: [String] = ["roku", "sai"]
    private let matchaWord = "抹茶"
    private let expectedMatchaRomaji = "matcha"
    private let fusedSanbonWord = "三本"
    private let expectedFusedSanbonRomaji = "sanbon"
    private let nunInsertionWord = "かんな"
    private let expectedNunInsertionRomaji = "kanna"
    private let vuFusionWord = "ヴァイオリン"
    private let expectedVuFusionRomaji = "vaiorin"

    // MARK: - Helpers

    private func firstSegment(of text: String) -> ReadingSegment? {
        ReadingAnnotator.segments(for: text)?.first
    }

    private func segment(_ surface: String, in text: String) -> ReadingSegment? {
        ReadingAnnotator.segments(for: text)?.first { $0.surface == surface }
    }

    // MARK: - Empty input

    func test_segments_whenTextIsEmpty_shouldReturnNil() {
        let result = ReadingAnnotator.segments(for: emptyText)

        XCTAssertNil(result)
    }

    func test_segments_whenTextIsWhitespaceOnly_shouldReturnNil() {
        let result = ReadingAnnotator.segments(for: whitespaceText)

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
        let segments = ReadingAnnotator.segments(for: particleSentence)
        let particle = segments?.first { $0.surface == particleSurface }

        let romaji = particle?.romaji

        XCTAssertEqual(romaji, expectedParticleRomaji)
    }

    func test_segments_whenPunctuatedSentence_shouldSplitIntoWordRuns() {
        let segments = ReadingAnnotator.segments(for: weatherSentence)
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
        let segments = ReadingAnnotator.segments(for: numberCounter)

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
        let segments = ReadingAnnotator.segments(for: weatherSentence)
        let punctuation = segments?.last

        let romaji = punctuation?.romaji

        XCTAssertNil(romaji)
    }

    // MARK: - Surfaces-concatenate-back invariant

    func test_segments_whenConcatenated_shouldReproduceTheOriginalText() {
        let texts = [weatherSentence, particleSentence, latinSentence, sokuonFusionSentence]

        for text in texts {
            let surfaces = ReadingAnnotator.segments(for: text)?.map(\.surface).joined()

            XCTAssertEqual(surfaces, text)
        }
    }

    func test_segments_whenRareIdeographTranscribesEmpty_shouldKeepSurface() {
        let surfaces = ReadingAnnotator.segments(for: rareIdeographSentence)?.map(\.surface).joined()

        XCTAssertEqual(surfaces, rareIdeographSentence)
    }

    func test_segments_whenExtAIdeograph_shouldProduceSelfTranscribedSegment() {
        let segment = firstSegment(of: extAIdeograph)

        XCTAssertEqual(segment?.surface, extAIdeograph)
        XCTAssertEqual(segment?.romaji, extAIdeograph)
    }

    // MARK: - Gaps and whitespace

    func test_segments_whenWhitespaceGap_shouldFoldSpaceIntoPreviousRun() {
        let segments = ReadingAnnotator.segments(for: latinSentence)
        let first = segments?.first

        XCTAssertEqual(first?.surface, "A ")
        XCTAssertEqual(first?.romaji, "A")
    }

    // MARK: - Straddling sokuon (~tsu)

    func test_segments_whenSokuonStraddlesTokens_shouldFuseIntoPreviousRun() {
        let segment = firstSegment(of: sokuonFusionSentence)

        XCTAssertEqual(segment?.surface, expectedSokuonFusionSurface)
        XCTAssertEqual(segment?.romaji, expectedSokuonFusionRomaji)
        XCTAssertEqual(segment?.furigana, expectedSokuonFusionFurigana)
    }

    func test_segments_whenSokuonCannotGeminateNextToken_shouldKeepSpokenTsu() {
        let segment = firstSegment(of: tsuFallbackSentence)

        XCTAssertEqual(segment?.surface, "おっ")
        XCTAssertEqual(segment?.romaji, expectedTsuFallbackRomaji)
    }

    func test_segments_whenSokuonEndsInput_shouldAppendSpokenTsu() {
        let segments = ReadingAnnotator.segments(for: trailingSokuonSentence)
        let last = segments?.last

        XCTAssertEqual(last?.surface, "言っ")
        XCTAssertEqual(last?.romaji, expectedTrailingSokuonRomaji)
    }

    // MARK: - Number + counter fusion variants

    func test_segments_whenJuugeminatesBeforeCounter_shouldFuse() {
        let segment = firstSegment(of: "十回")

        XCTAssertEqual(segment?.romaji, "jukkai")
        XCTAssertEqual(segment?.furigana, "じゅっかい")
    }

    func test_segments_whenRokuKeepsPlainReading_shouldNotFuse() {
        let segments = ReadingAnnotator.segments(for: rokuExceptionWord)
        let romajiList = segments?.map { $0.romaji ?? "" }

        XCTAssertEqual(romajiList, expectedRokuExceptionSegments)
    }

    func test_segments_whenRokuKeepsPlainReadingBeforeTou_shouldNotFuse() {
        let segments = ReadingAnnotator.segments(for: "六等")
        let romajiList = segments?.map { $0.romaji ?? "" }

        XCTAssertEqual(romajiList, ["roku", "tou"])
    }

    func test_segments_whenHonFollowsUnvoicedNumber_shouldRestoreHon() {
        let segments = ReadingAnnotator.segments(for: plainHonSentence)
        let hon = segments?.last

        XCTAssertEqual(hon?.surface, "本")
        XCTAssertEqual(hon?.romaji, expectedPlainHonReading)
    }

    func test_segments_whenHonFollowsVoicedNumber_shouldRestoreBon() {
        let segments = ReadingAnnotator.segments(for: voicedHonSentence)
        let hon = segments?.last

        XCTAssertEqual(hon?.surface, "本")
        XCTAssertEqual(hon?.romaji, expectedVoicedHonReading)
    }

    func test_segments_whenNumberFollowsNonKaCounter_shouldNotFuseDateStem() {
        let segments = ReadingAnnotator.segments(for: "七回")
        let romajiList = segments?.map { $0.romaji ?? "" }

        XCTAssertEqual(romajiList, ["nana", "kai"])
    }

    func test_segments_whenSokuonBeforeChiRowCounter_shouldGeminateWithC() {
        let segment = firstSegment(of: "一着")

        XCTAssertEqual(segment?.surface, "一着")
        XCTAssertEqual(segment?.romaji, "icchaku")
    }

    func test_segments_whenSokuonBeforeFuRowCounter_shouldGeminateAsPp() {
        let segment = firstSegment(of: "八分")

        XCTAssertEqual(segment?.surface, "八分")
        XCTAssertEqual(segment?.romaji, "happun")
    }

    func test_segments_whenInputIsEmptyOrWhitespace_shouldReturnNil() {
        XCTAssertNil(ReadingAnnotator.segments(for: ""))
        XCTAssertNil(ReadingAnnotator.segments(for: "   "))
        XCTAssertNil(ReadingAnnotator.segments(for: "\n\t "))
    }

    func test_segments_whenNumberHeldBackAcrossGap_shouldFlushNumberBeforeGap() {
        let segments = ReadingAnnotator.segments(for: "三、四本")
        let romajiList = segments?.map { $0.romaji }

        XCTAssertEqual(romajiList, ["san", nil, "yon", "hon"])
    }

    // MARK: - Date counters

    func test_segments_whenDateCounterStemFusesWithKa_shouldFuseStem() {
        let segment = firstSegment(of: dateCounterWord)

        XCTAssertEqual(segment?.surface, dateCounterWord)
        XCTAssertEqual(segment?.romaji, expectedDateCounterRomaji)
    }

    func test_segments_whenDateCounterSplitsViaSokuon_shouldGeminate() {
        let segment = firstSegment(of: sokuonDateCounterWord)

        XCTAssertEqual(segment?.surface, sokuonDateCounterWord)
        XCTAssertEqual(segment?.romaji, expectedSokuonDateCounterRomaji)
        XCTAssertEqual(segment?.furigana, "みっか")
    }

    func test_segments_whenMultiCharacterDateCounter_shouldFuseStem() {
        let segment = firstSegment(of: multiCharDateCounterWord)

        XCTAssertEqual(segment?.romaji, expectedMultiCharDateCounterRomaji)
    }

    func test_segments_whenDatePairOverrideYonNichi_shouldFuseToYokka() {
        let segment = firstSegment(of: datePairOverrideWord)

        XCTAssertEqual(segment?.surface, datePairOverrideWord)
        XCTAssertEqual(segment?.romaji, expectedDatePairOverrideRomaji)
    }

    func test_segments_whenDatePairOverrideNanaNichi_shouldFuseToNanoka() {
        let segment = firstSegment(of: secondDatePairOverrideWord)

        XCTAssertEqual(segment?.surface, secondDatePairOverrideWord)
        XCTAssertEqual(segment?.romaji, expectedSecondDatePairOverrideRomaji)
    }

    // MARK: - Lexical overrides

    func test_segments_whenMatchaSurface_shouldOverrideWithLoanwordSpelling() {
        let segment = firstSegment(of: matchaWord)

        XCTAssertEqual(segment?.romaji, expectedMatchaRomaji)
    }

    func test_segments_whenSanbonFusedByTokenizer_shouldOverrideFamilyReading() {
        let segment = firstSegment(of: fusedSanbonWord)

        XCTAssertEqual(segment?.romaji, expectedFusedSanbonRomaji)
    }

    // MARK: - Romaji corrections

    func test_segments_whenNNBeforeNaRow_shouldWriteDoubledN() {
        let segment = firstSegment(of: nunInsertionWord)

        XCTAssertEqual(segment?.romaji, expectedNunInsertionRomaji)
    }

    func test_segments_whenTchSpelling_shouldNormalizeToCch() {
        let segment = firstSegment(of: "めっちゃ")

        XCTAssertEqual(segment?.romaji, "meccha")
    }

    func test_segments_whenVuMorphemeBreak_shouldFuse() {
        let segment = firstSegment(of: vuFusionWord)

        XCTAssertEqual(segment?.romaji, expectedVuFusionRomaji)
    }

    func test_segments_whenDirectionalParticle_shouldRomanizeAsE() {
        let segment = segment("へ", in: directionalParticle)

        XCTAssertEqual(segment?.romaji, expectedDirectionalParticleRomaji)
    }

    func test_segments_whenTopicParticleAlone_shouldRomanizeAsWa() {
        let segment = firstSegment(of: "は")

        XCTAssertEqual(segment?.romaji, "wa")
    }

    func test_segments_whenObjectParticleAlone_shouldRomanizeAsO() {
        let segment = firstSegment(of: "を")

        XCTAssertEqual(segment?.romaji, "o")
    }

    // MARK: - Kanji detection

    func test_segments_whenRepeatedMarkSurface_shouldAnnotateAsKanji() {
        let segment = firstSegment(of: repeatedKanjiWord)

        XCTAssertEqual(segment?.furigana, expectedRepeatedKanjiFurigana)
    }

    func test_segments_whenNunBeforeNaRowKanji_shouldAnnotateDoubledN() {
        let segment = firstSegment(of: "案内")

        XCTAssertEqual(segment?.furigana, "あんない")
    }

    func test_segments_whenGeminateChiKanji_shouldAnnotateSokuon() {
        let segment = firstSegment(of: "一致")

        XCTAssertEqual(segment?.furigana, "いっち")
    }

    // MARK: - Cache

    func test_segments_whenCalledTwiceForSameText_shouldReturnCachedSegments() {
        let first = ReadingAnnotator.segments(for: weatherSentence)
        let second = ReadingAnnotator.segments(for: weatherSentence)

        XCTAssertEqual(first?.first === second?.first, true)
    }
}
