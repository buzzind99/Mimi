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

    // MARK: - expandMacrons

    func test_expandMacrons_whenMacronVowel_shouldExpandToWapuroSpelling() {
        let expanded = KanaConversion.expandMacrons(macronText)

        XCTAssertEqual(expanded, expectedExpandedText)
    }
}
