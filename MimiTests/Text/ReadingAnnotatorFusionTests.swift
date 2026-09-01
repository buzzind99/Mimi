import Foundation
@testable import Mimi
import Testing

// MARK: - Numeral → counter fusion

@Suite("ReadingAnnotator numeral fusion")
struct ReadingAnnotatorFusionTests {

    @Test("fuses Arabic digits with a geminating counter (600回 → roppyakkai)")
    func digitCounterFusion() throws {
        let annotator = makeAnnotator(tokens(
            ["6", "0", "0", "回"],
            readings: [[], [], [], [kana("かい", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "600回"))

        #expect(describe(segments) == [["600回", "roppyakkai", "ろっぴゃっかい"]])
    }

    @Test("normalizes fullwidth digits before fusion (６００回 → roppyakkai)")
    func fullwidthDigitFusion() throws {
        let annotator = makeAnnotator(tokens(
            ["６", "０", "０", "回"],
            readings: [[], [], [], [kana("かい", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "６００回"))

        #expect(describe(segments) == [["６００回", "roppyakkai", "ろっぴゃっかい"]])
    }

    @Test("fuses tens digits with a geminating counter (60回 → rokujukkai)")
    func tensDigitFusion() throws {
        let annotator = makeAnnotator(tokens(
            ["6", "0", "回"], readings: [[], [], [kana("かい", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "60回"))

        #expect(describe(segments) == [["60回", "rokujukkai", "ろくじゅっかい"]])
    }

    @Test("fuses a kanji numeral with a geminating counter (八歳 → hassai)")
    func kanjiNumeralFusion() throws {
        let annotator = makeAnnotator(tokens(
            ["八", "歳"],
            readings: [[kana("はち", priority: "ichi1")], [kana("さい", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "八歳"))

        #expect(describe(segments) == [["八歳", "hassai", "はっさい"]])
    }

    @Test("keeps the number as its own segment when the counter can't geminate (2日)")
    func geminateNilFlushesNumber() throws {
        let annotator = makeAnnotator(tokens(
            ["2", "日"], readings: [[], [kana("にち", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "2日"))

        #expect(describe(segments) == [["2", "ni", nil], ["日", "nichi", "にち"]])
    }

    @Test("keeps 六 separate before 歳 (roku exception)")
    func rokuExceptionBeforeSai() throws {
        let annotator = makeAnnotator(tokens(
            ["六", "歳"],
            readings: [[kana("ろく", priority: "ichi1")], [kana("さい", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "六歳"))

        #expect(describe(segments) == [["六", "roku", "ろく"], ["歳", "sai", "さい"]])
    }

    @Test("keeps the digit 6 separate before 歳 (roku exception)")
    func rokuExceptionDigitBeforeSai() throws {
        let annotator = makeAnnotator(tokens(
            ["6", "歳"], readings: [[], [kana("さい", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "6歳"))

        #expect(describe(segments) == [["6", "roku", nil], ["歳", "sai", "さい"]])
    }

    @Test("accumulates consecutive kanji numerals into one run (千 is itself a numeral)")
    func senAccumulatesIntoTheNumberRun() throws {
        let annotator = makeAnnotator(tokens(
            ["六", "千"],
            readings: [[kana("ろく", priority: "ichi1")], [kana("せん", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "六千"))

        #expect(describe(segments) == [["六千", "rokusen", "ろくせん"]])
    }

    @Test("keeps 六 separate before the とう reading of 等 (roku exception)")
    func rokuExceptionBeforeTou() throws {
        let annotator = makeAnnotator(tokens(
            ["六", "等"],
            readings: [[kana("ろく", priority: "ichi1")], [kana("とう", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "六等"))

        #expect(describe(segments) == [["六", "roku", "ろく"], ["等", "tou", "とう"]])
    }

    @Test("voices 本 to bon after さん/まん, with furigana ほん (三万本)")
    func voicedHon() throws {
        let annotator = makeAnnotator(tokens(
            ["三", "万", "本"],
            readings: [
                [kana("さん", priority: "ichi1")],
                [kana("まん", priority: "ichi1")],
                [kana("もと", priority: "ichi1")]
            ]
        ))

        let segments = try #require(annotator.segments(for: "三万本"))

        #expect(describe(segments) == [["三万", "sanman", "さんまん"], ["本", "bon", "ほん"]])
    }

    @Test("flushes the held-back number before a gap (三、四本)")
    func flushBeforeGap() throws {
        let annotator = makeAnnotator(tokens(
            ["三", "、", "四本"],
            readings: [[kana("さん", priority: "ichi1")], [], [kana("よんほん", priority: "news1")]]
        ))

        let segments = try #require(annotator.segments(for: "三、四本"))

        #expect(describe(segments) == [
            ["三", "san", "さん"], ["、", "、", nil], ["四本", "yonhon", "よんほん"]
        ])
    }

    @Test("reads 年 as the counter after resolved digits (2年 → ni nen)")
    func yearAfterDigits() throws {
        let annotator = makeAnnotator(tokens(
            ["2", "年"], readings: [[], [kana("とし", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "2年"))

        #expect(describe(segments) == [["2", "ni", nil], ["年", "nen", "ねん"]])
    }

    @Test("reads 年 as the counter after a kanji numeral (八年 → hachi nen)")
    func yearAfterKanjiNumeral() throws {
        let annotator = makeAnnotator(tokens(
            ["八", "年"],
            readings: [[kana("はち", priority: "ichi1")], [kana("とし", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "八年"))

        #expect(describe(segments) == [["八", "hachi", "はち"], ["年", "nen", "ねん"]])
    }

    @Test("reads 年 as the counter after unresolved digits (2026年)")
    func yearAfterUnresolvedDigits() throws {
        let annotator = makeAnnotator(tokens(
            ["2", "0", "2", "6", "年"],
            readings: [[], [], [], [], [kana("とし", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "2026年"))

        #expect(describe(segments) == [["2026", "2026", nil], ["年", "nen", "ねん"]])
    }

    @Test("leaves bare digit runs unannotated (123)")
    func bareDigitsUnannotated() throws {
        let annotator = makeAnnotator(tokens(
            ["1", "2", "3"], readings: [[], [], []]
        ))

        let segments = try #require(annotator.segments(for: "123"))

        #expect(describe(segments) == [["123", "123", nil]])
    }

    @Test("accumulates digits with a following kanji numeral (3万 → sanman)")
    func mixedAccumulation() throws {
        let annotator = makeAnnotator(tokens(
            ["3", "万"], readings: [[], [kana("まん", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "3万"))

        #expect(describe(segments) == [["3万", "sanman", "さんまん"]])
    }

    @Test("resolves a digit run before a kanji numeral (3千 → sansen)")
    func digitRunBeforeKanjiNumeral() throws {
        let annotator = makeAnnotator(tokens(
            ["3", "千"], readings: [[], [kana("せん", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "3千"))

        #expect(describe(segments) == [["3千", "sansen", "さんせん"]])
    }

    @Test("stays unannotated when a numeral after digits has no reading (1千)")
    func unreadableKanjiNumeralAfterDigits() throws {
        let annotator = makeAnnotator(tokens(
            ["1", "千"], readings: [[], []]
        ))

        let segments = try #require(annotator.segments(for: "1千"))

        #expect(describe(segments) == [["1千", "1千", nil]])
    }

    @Test("flushes a trailing held-back number as its own segment (六)")
    func trailingNumberFlushes() throws {
        let annotator = makeAnnotator(tokens(
            ["六"], readings: [[kana("ろく", priority: "ichi1")]]
        ))

        let segments = try #require(annotator.segments(for: "六"))

        #expect(describe(segments) == [["六", "roku", "ろく"]])
    }
}
