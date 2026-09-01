@testable import Mimi
import XCTest

/// Tests the kana → wapuro-romaji conversion through the public
/// `KanaRomaji.romaji(fromKana:)` entry point. Expected values are the
/// romaji strings the annotation suite pins (see `ReadingAnnotatorTests`);
/// the "legacy corpus" section doubles as the round-trip spot check
/// `KanaRomaji(legacy furigana/kana reading) == legacy romaji` for the
/// shared counter/date/honorific corpus.
final class KanaRomajiTests: XCTestCase {

    // MARK: - Fixtures

    private let plainKana = "さくら"
    private let expectedPlainRomaji = "sakura"
    private let geminatedKana = "いっかい"
    private let expectedGeminatedRomaji = "ikkai"
    private let geminatedPyaKana = "ろっぴゃく"
    private let expectedGeminatedPyaRomaji = "roppyaku"
    private let geminatedChiKana = "めっちゃ"
    private let expectedGeminatedChiRomaji = "meccha"
    private let honorificKana = "かんな"
    private let expectedHonorificRomaji = "kanna"
    private let apostropheNKana = "まんいん"
    private let expectedApostropheNRomaji = "man'in"
    private let digits = "123"
    private let emptyKana = ""

    // MARK: - Plain morae

    func test_romaji_whenPlainHiragana_shouldConvertEachMora() {
        let romaji = KanaRomaji.romaji(fromKana: plainKana)

        XCTAssertEqual(romaji, expectedPlainRomaji)
    }

    func test_romaji_whenSingleVowels_shouldMapToVowelLetters() {
        let romaji = KanaRomaji.romaji(fromKana: "あいうえお")

        XCTAssertEqual(romaji, "aiueo")
    }

    func test_romaji_whenShi_shouldUseHepburnSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "し")

        XCTAssertEqual(romaji, "shi")
    }

    func test_romaji_whenChi_shouldUseHepburnSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "ち")

        XCTAssertEqual(romaji, "chi")
    }

    func test_romaji_whenTsu_shouldUseHepburnSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "つ")

        XCTAssertEqual(romaji, "tsu")
    }

    func test_romaji_whenConsonantVowelPairs_shouldUseRowSpellings() {
        let romaji = KanaRomaji.romaji(fromKana: "ひと")

        XCTAssertEqual(romaji, "hito")
    }

    func test_romaji_whenWo_shouldKeepHistoricalSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "を")

        XCTAssertEqual(romaji, "wo")
    }

    func test_romaji_whenKatakana_shouldConvertLikeHiragana() {
        let romaji = KanaRomaji.romaji(fromKana: "サクラ")

        XCTAssertEqual(romaji, expectedPlainRomaji)
    }

    func test_romaji_whenVu_shouldUseVSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "ヴ")

        XCTAssertEqual(romaji, "vu")
    }

    // MARK: - Digraphs

    func test_romaji_whenYDigraph_shouldUseThreeLetterSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "しゃ")

        XCTAssertEqual(romaji, "sha")
    }

    func test_romaji_whenRRowYDigraph_shouldUseThreeLetterSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "りゃ")

        XCTAssertEqual(romaji, "rya")
    }

    func test_romaji_whenPRowYDigraph_shouldUseThreeLetterSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "ぴょ")

        XCTAssertEqual(romaji, "pyo")
    }

    func test_romaji_whenForeignFaDigraph_shouldUseForeignSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "ファ")

        XCTAssertEqual(romaji, "fa")
    }

    func test_romaji_whenForeignVaDigraph_shouldUseForeignSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "ヴァ")

        XCTAssertEqual(romaji, "va")
    }

    func test_romaji_whenForeignTiDigraph_shouldUseForeignSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "ティ")

        XCTAssertEqual(romaji, "ti")
    }

    func test_romaji_whenForeignTuDigraph_shouldUseForeignSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "とぅ")

        XCTAssertEqual(romaji, "tu")
    }

    func test_romaji_whenForeignWoDigraph_shouldUseForeignSpelling() {
        let romaji = KanaRomaji.romaji(fromKana: "ウォ")

        XCTAssertEqual(romaji, "wo")
    }

    // MARK: - Long vowels

    func test_romaji_whenMorabicLongVowel_shouldStayMoraByMora() {
        let romaji = KanaRomaji.romaji(fromKana: "とう")

        XCTAssertEqual(romaji, "tou")
    }

    func test_romaji_whenDigraphPlusU_shouldStayMoraByMora() {
        let romaji = KanaRomaji.romaji(fromKana: "じゅう")

        XCTAssertEqual(romaji, "juu")
    }

    func test_romaji_whenOThenU_shouldStayMoraByMora() {
        let romaji = KanaRomaji.romaji(fromKana: "おう")

        XCTAssertEqual(romaji, "ou")
    }

    func test_romaji_whenChoonpu_shouldRepeatPreviousVowel() {
        let romaji = KanaRomaji.romaji(fromKana: "コーヒー")

        XCTAssertEqual(romaji, "koohii")
    }

    func test_romaji_whenHiraganaChoonpu_shouldRepeatPreviousVowel() {
        let romaji = KanaRomaji.romaji(fromKana: "うーん")

        XCTAssertEqual(romaji, "uun")
    }

    func test_romaji_whenChoonpuAfterMoraicN_shouldReturnNil() {
        // Defensive: ん can't be prolonged, so ー after it fails instead of
        // repeating the previous mora's vowel.
        let romaji = KanaRomaji.romaji(fromKana: "まんー")

        XCTAssertNil(romaji)
    }

    // MARK: - Sokuon

    func test_romaji_whenSokuonBeforeKai_shouldDoubleConsonant() {
        let romaji = KanaRomaji.romaji(fromKana: geminatedKana)

        XCTAssertEqual(romaji, expectedGeminatedRomaji)
    }

    func test_romaji_whenSokuonBeforeDigraph_shouldDoubleConsonant() {
        let romaji = KanaRomaji.romaji(fromKana: geminatedPyaKana)

        XCTAssertEqual(romaji, expectedGeminatedPyaRomaji)
    }

    func test_romaji_whenSokuonBeforeChiRow_shouldGeminateAsCch() {
        let romaji = KanaRomaji.romaji(fromKana: geminatedChiKana)

        XCTAssertEqual(romaji, expectedGeminatedChiRomaji)
    }

    func test_romaji_whenSokuonBeforeTsu_shouldGeminateAsTtsu() {
        let romaji = KanaRomaji.romaji(fromKana: "いっつ")

        XCTAssertEqual(romaji, "ittsu")
    }

    func test_romaji_whenSokuonBeforeHaRow_shouldRealizeAsPSeries() {
        let romaji = KanaRomaji.romaji(fromKana: "はっは")

        XCTAssertEqual(romaji, "happa")
    }

    func test_romaji_whenSokuonBeforeFuRow_shouldRealizeAsPSeries() {
        let romaji = KanaRomaji.romaji(fromKana: "はっぷん")

        XCTAssertEqual(romaji, "happun")
    }

    func test_romaji_whenSokuonBeforeHiRow_shouldRealizeAsPSeries() {
        let romaji = KanaRomaji.romaji(fromKana: "はっぴき")

        XCTAssertEqual(romaji, "happiki")
    }

    func test_romaji_whenSokuonBeforeLoanD_shouldDoubleConsonant() {
        let romaji = KanaRomaji.romaji(fromKana: "ベッド")

        XCTAssertEqual(romaji, "beddo")
    }

    func test_romaji_whenSokuonBeforeLoanJ_shouldDoubleConsonant() {
        let romaji = KanaRomaji.romaji(fromKana: "エッジ")

        XCTAssertEqual(romaji, "ejji")
    }

    func test_romaji_whenKatakanaSokuon_shouldGeminate() {
        let romaji = KanaRomaji.romaji(fromKana: "ラッパ")

        XCTAssertEqual(romaji, "rappa")
    }

    func test_romaji_whenSokuonEndsInput_shouldSpeakStandaloneTsu() {
        let romaji = KanaRomaji.romaji(fromKana: "おっ")

        XCTAssertEqual(romaji, "otsu")
    }

    func test_romaji_whenSokuonBeforeVowel_shouldSpeakStandaloneTsu() {
        // Defensive: no dictionary reading puts っ before a vowel; the
        // sokuon degrades to a spoken "tsu".
        let romaji = KanaRomaji.romaji(fromKana: "っあ")

        XCTAssertEqual(romaji, "tsua")
    }

    func test_romaji_whenSokuonBeforeUnmappableMora_shouldReturnNil() {
        // Defensive: a sokuon followed by a kanji falls through the "tsu"
        // path and the unmappable mora still fails the conversion.
        let romaji = KanaRomaji.romaji(fromKana: "あっ漢")

        XCTAssertNil(romaji)
    }

    func test_romaji_whenChoonpuAfterStandaloneTsu_shouldReturnNil() {
        // Defensive: a spoken "tsu" can't be prolonged, so ー after a
        // stranded sokuon fails instead of repeating a stale vowel.
        let romaji = KanaRomaji.romaji(fromKana: "っー")

        XCTAssertNil(romaji)
    }

    func test_romaji_whenDoubledVowel_shouldNotEmitSokuon() {
        let romaji = KanaRomaji.romaji(fromKana: "おおきい")

        XCTAssertEqual(romaji, "ookii")
    }

    // MARK: - Moraic n

    func test_romaji_whenFinalN_shouldEmitMoraicN() {
        let romaji = KanaRomaji.romaji(fromKana: "さん")

        XCTAssertEqual(romaji, "san")
    }

    func test_romaji_whenNBeforeConsonant_shouldEmitPlainN() {
        let romaji = KanaRomaji.romaji(fromKana: "あんた")

        XCTAssertEqual(romaji, "anta")
    }

    func test_romaji_whenNBeforeNaRow_shouldEmitPlainN() {
        let romaji = KanaRomaji.romaji(fromKana: honorificKana)

        XCTAssertEqual(romaji, expectedHonorificRomaji)
    }

    func test_romaji_whenNBeforeVowel_shouldUseApostrophe() {
        let romaji = KanaRomaji.romaji(fromKana: apostropheNKana)

        XCTAssertEqual(romaji, expectedApostropheNRomaji)
    }

    func test_romaji_whenNBeforeYaRow_shouldUseApostrophe() {
        let romaji = KanaRomaji.romaji(fromKana: "げんや")

        XCTAssertEqual(romaji, "gen'ya")
    }

    func test_romaji_whenDoubleNBeforeVowelSyllable_shouldWriteDoubledN() {
        let romaji = KanaRomaji.romaji(fromKana: "あんない")

        XCTAssertEqual(romaji, "annai")
    }

    func test_romaji_whenNBetweenSyllables_shouldWriteDoubledN() {
        let romaji = KanaRomaji.romaji(fromKana: "さんにん")

        XCTAssertEqual(romaji, "sannin")
    }

    func test_romaji_whenHaAsPlainKana_shouldUseHistoricalSpelling() {
        // The converter is context-free: は maps to "ha"; the particle
        // reading ("wa") is the annotator's override.
        let romaji = KanaRomaji.romaji(fromKana: "こんにちは")

        XCTAssertEqual(romaji, "konnichiha")
    }

    // MARK: - Historical voiced kana

    func test_romaji_whenDzuInWord_shouldVoiceToZu() {
        let romaji = KanaRomaji.romaji(fromKana: "つづり")

        XCTAssertEqual(romaji, "tsuzuri")
    }

    func test_romaji_whenDiInWord_shouldVoiceToJi() {
        let romaji = KanaRomaji.romaji(fromKana: "はなぢ")

        XCTAssertEqual(romaji, "hanaji")
    }

    // MARK: - Legacy corpus round-trip

    func test_romaji_whenIppon_shouldMatchLegacyRomaji() {
        let romaji = KanaRomaji.romaji(fromKana: "いっぽん")

        XCTAssertEqual(romaji, "ippon")
    }

    func test_romaji_whenHassai_shouldMatchLegacyRomaji() {
        let romaji = KanaRomaji.romaji(fromKana: "はっさい")

        XCTAssertEqual(romaji, "hassai")
    }

    func test_romaji_whenYokka_shouldMatchLegacyRomaji() {
        let romaji = KanaRomaji.romaji(fromKana: "よっか")

        XCTAssertEqual(romaji, "yokka")
    }

    func test_romaji_whenHatachi_shouldMatchLegacyRomaji() {
        let romaji = KanaRomaji.romaji(fromKana: "はたち")

        XCTAssertEqual(romaji, "hatachi")
    }

    func test_romaji_whenKaasan_shouldMatchLegacyRomaji() {
        let romaji = KanaRomaji.romaji(fromKana: "かあさん")

        XCTAssertEqual(romaji, "kaasan")
    }

    func test_romaji_whenOkaasama_shouldMatchLegacyRomaji() {
        let romaji = KanaRomaji.romaji(fromKana: "おかあさま")

        XCTAssertEqual(romaji, "okaasama")
    }

    func test_romaji_whenOkaasan_shouldMatchLegacyFurigana() {
        let romaji = KanaRomaji.romaji(fromKana: "おかあさん")

        XCTAssertEqual(romaji, "okaasan")
    }

    func test_romaji_whenJukkai_shouldMatchLegacyFurigana() {
        let romaji = KanaRomaji.romaji(fromKana: "じゅっかい")

        XCTAssertEqual(romaji, "jukkai")
    }

    func test_romaji_whenMikka_shouldMatchLegacyFurigana() {
        let romaji = KanaRomaji.romaji(fromKana: "みっか")

        XCTAssertEqual(romaji, "mikka")
    }

    func test_romaji_whenItte_shouldMatchLegacyFurigana() {
        let romaji = KanaRomaji.romaji(fromKana: "いって")

        XCTAssertEqual(romaji, "itte")
    }

    func test_romaji_whenTokidoki_shouldMatchLegacyFurigana() {
        let romaji = KanaRomaji.romaji(fromKana: "ときどき")

        XCTAssertEqual(romaji, "tokidoki")
    }

    func test_romaji_whenIcchi_shouldMatchLegacyFurigana() {
        let romaji = KanaRomaji.romaji(fromKana: "いっち")

        XCTAssertEqual(romaji, "icchi")
    }

    func test_romaji_whenHaha_shouldMatchLegacyFurigana() {
        let romaji = KanaRomaji.romaji(fromKana: "はは")

        XCTAssertEqual(romaji, "haha")
    }

    // MARK: - Unmappable input

    func test_romaji_whenEmptyInput_shouldReturnNil() {
        let romaji = KanaRomaji.romaji(fromKana: emptyKana)

        XCTAssertNil(romaji)
    }

    func test_romaji_whenDigits_shouldReturnNil() {
        let romaji = KanaRomaji.romaji(fromKana: digits)

        XCTAssertNil(romaji)
    }

    func test_romaji_whenUnmappableCharacterMidString_shouldReturnNil() {
        let romaji = KanaRomaji.romaji(fromKana: "くら3ね")

        XCTAssertNil(romaji)
    }

    func test_romaji_whenKanjiPresent_shouldReturnNil() {
        let romaji = KanaRomaji.romaji(fromKana: "テスト漢字")

        XCTAssertNil(romaji)
    }

    func test_romaji_whenLeadingChoonpu_shouldReturnNil() {
        let romaji = KanaRomaji.romaji(fromKana: "ー")

        XCTAssertNil(romaji)
    }

    func test_romaji_whenNBeforeUnmappableCharacter_shouldReturnNil() {
        let romaji = KanaRomaji.romaji(fromKana: "あん漢")

        XCTAssertNil(romaji)
    }

    // MARK: - Normalization

    func test_romaji_whenDecomposedVoicingMark_shouldComposeBeforeMapping() {
        // か + combining voiced sound mark must behave like precomposed が.
        let decomposedGaku = "か\u{3099}く"

        let romaji = KanaRomaji.romaji(fromKana: decomposedGaku)

        XCTAssertEqual(romaji, "gaku")
    }
}
