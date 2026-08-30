@testable import Mimi
import XCTest

/// Tests the wapuro-romaji → hiragana conversion through the public
/// `KanaConversion.kana(fromRomaji:)` and `expandMacrons(_:)` entry points.
final class KanaConversionTests: XCTestCase {

    // MARK: - Fixtures

    private let geminatedRomaji = "ikkai"
    private let expectedGeminatedKana = "いっかい"
    private let plainRomaji = "sakura"
    private let expectedPlainKana = "さくら"
    private let longVowelRomaji = "kyou"
    private let expectedLongVowelKana = "きょう"
    private let digits = "123"
    private let emptyRomaji = ""
    private let macronText = "kyō"
    private let expectedExpandedText = "kyou"

    // MARK: - kana(fromRomaji:)

    func test_kana_whenGeminatedRomaji_shouldProduceSokuon() {
        let kana = KanaConversion.kana(fromRomaji: geminatedRomaji)

        XCTAssertEqual(kana, expectedGeminatedKana)
    }

    func test_kana_whenPlainRomaji_shouldConvertEachMora() {
        let kana = KanaConversion.kana(fromRomaji: plainRomaji)

        XCTAssertEqual(kana, expectedPlainKana)
    }

    func test_kana_whenLongVowelRomaji_shouldComposeLongVowel() {
        let kana = KanaConversion.kana(fromRomaji: longVowelRomaji)

        XCTAssertEqual(kana, expectedLongVowelKana)
    }

    func test_kana_whenUnmappableCharacters_shouldReturnNil() {
        let kana = KanaConversion.kana(fromRomaji: digits)

        XCTAssertNil(kana)
    }

    func test_kana_whenEmptyRomaji_shouldReturnNil() {
        let kana = KanaConversion.kana(fromRomaji: emptyRomaji)

        XCTAssertNil(kana)
    }

    func test_kana_whenUnmappableCharacterMidString_shouldReturnNil() {
        let kana = KanaConversion.kana(fromRomaji: "kura3ne")

        XCTAssertNil(kana)
    }

    // MARK: - Dispatch priority (triples → pairs → n → sokuon → singles)

    func test_kana_whenThreeLetterSpelling_shouldUseTripleTable() {
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "tsuki"), "つき")
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "shi"), "し")
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "cchi"), "っち")
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "tso"), "つぉ")
    }

    func test_kana_whenDigraphSpelling_shouldUseTripleDigraph() {
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "sha"), "しゃ")
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "chu"), "ちゅ")
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "rya"), "りゃ")
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "pyo"), "ぴょ")
    }

    func test_kana_whenTwoLetterSpelling_shouldUsePairTable() {
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "sushi"), "すし")
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "hito"), "ひと")
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "wo"), "を")
    }

    func test_kana_whenSingleVowel_shouldUseSingleTable() {
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "aiueo"), "あいうえお")
    }

    // MARK: - Moraic n

    func test_kana_whenFinalN_shouldEmitMoraicN() {
        let kana = KanaConversion.kana(fromRomaji: "san")

        XCTAssertEqual(kana, "さん")
    }

    func test_kana_whenApostropheN_shouldEmitMoraicNAndConsumeApostrophe() {
        let kana = KanaConversion.kana(fromRomaji: "man'in")

        XCTAssertEqual(kana, "まんいん")
    }

    func test_kana_whenDoubleN_shouldEmitMoraicNAndSecondN() {
        let kana = KanaConversion.kana(fromRomaji: "kanna")

        XCTAssertEqual(kana, "かんな")
    }

    func test_kana_whenDoubleNBeforeVowelSyllable_shouldNotSwallowNextConsonant() {
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "annai"), "あんない")
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "sannin"), "さんにん")
    }

    func test_kana_whenGeminateChiPrefix_shouldEmitSokuonAndCompleteMora() {
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "itchi"), "いっち")
        XCTAssertEqual(KanaConversion.kana(fromRomaji: "meccha"), "めっちゃ")
    }

    func test_kana_whenNBeforeConsonant_shouldEmitMoraicN() {
        let kana = KanaConversion.kana(fromRomaji: "anta")

        XCTAssertEqual(kana, "あんた")
    }

    func test_kana_whenFailedNydigraph_shouldReturnNil() {
        let kana = KanaConversion.kana(fromRomaji: "onyx")

        XCTAssertNil(kana)
    }

    // MARK: - Sokuon

    func test_kana_whenDoubledConsonant_shouldEmitSokuon() {
        let kana = KanaConversion.kana(fromRomaji: geminatedRomaji)

        XCTAssertEqual(kana, expectedGeminatedKana)
    }

    func test_kana_whenDoubledPBeforeDigraph_shouldEmitSokuonAndDigraph() {
        let kana = KanaConversion.kana(fromRomaji: "roppyaku")

        XCTAssertEqual(kana, "ろっぴゃく")
    }

    func test_kana_whenDoubledVowel_shouldNotEmitSokuon() {
        let kana = KanaConversion.kana(fromRomaji: "ookii")

        XCTAssertEqual(kana, "おおきい")
    }

    // MARK: - Case and macron handling

    func test_kana_whenUppercaseInput_shouldLowercaseBeforeMapping() {
        let kana = KanaConversion.kana(fromRomaji: "SAKURA")

        XCTAssertEqual(kana, expectedPlainKana)
    }

    func test_kana_whenUppercaseMacronInput_shouldExpandMacronAfterLowercasing() {
        let kana = KanaConversion.kana(fromRomaji: "Ōsaka")

        XCTAssertEqual(kana, "おうさか")
    }

    // MARK: - expandMacrons

    func test_expandMacrons_whenMacronVowel_shouldExpandToWapuroSpelling() {
        let expanded = KanaConversion.expandMacrons(macronText)

        XCTAssertEqual(expanded, expectedExpandedText)
    }
}
