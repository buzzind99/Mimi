import Foundation
@testable import Mimi
import Testing

// MARK: - Numeral → counter fusion

@Suite("ReadingAnnotator numeral fusion")
struct ReadingAnnotatorFusionTests {

    @Test("fuses an Arabic digit token with a geminating counter (600回 → roppyakkai)")
    func digitCounterFusion() throws {
        let annotator = makeAnnotator(tokens(
            ["600", "回"],
            readings: [nil, "かい"]
        ))

        let segments = try #require(annotator.segments(for: "600回"))

        #expect(describe(segments) == [["600回", "roppyakkai", "ろっぴゃっかい"]])
    }

    @Test("normalizes fullwidth digits before fusion, ignoring their readings (６００回 → roppyakkai)")
    func fullwidthDigitFusion() throws {
        let annotator = makeAnnotator(tokens(
            ["６", "０", "０", "回"],
            readings: ["ろく", "ぜろ", "ぜろ", "かい"]
        ))

        let segments = try #require(annotator.segments(for: "６００回"))

        #expect(describe(segments) == [["６００回", "roppyakkai", "ろっぴゃっかい"]])
    }

    @Test("fuses a multi-digit run with a geminating counter (60回 → rokujukkai)")
    func tensDigitFusion() throws {
        let annotator = makeAnnotator(tokens(
            ["60", "回"], readings: [nil, "かい"]
        ))

        let segments = try #require(annotator.segments(for: "60回"))

        #expect(describe(segments) == [["60回", "rokujukkai", "ろくじゅっかい"]])
    }

    @Test("fuses a kanji numeral with a geminating counter (八歳 → hassai)")
    func kanjiNumeralFusion() throws {
        let annotator = makeAnnotator(tokens(
            ["八", "歳"], readings: ["はち", "さい"]
        ))

        let segments = try #require(annotator.segments(for: "八歳"))

        #expect(describe(segments) == [["八歳", "hassai", "はっさい"]])
    }

    @Test("reads irregular digit dates as one fused word (2日 → futsuka; 1日…10日, 14日, 20日, 24日)",
          arguments: [
              (["1", "日"], "1日", "tsuitachi", "ついたち"),
              (["2", "日"], "2日", "futsuka", "ふつか"),
              (["3", "日"], "3日", "mikka", "みっか"),
              (["4", "日"], "4日", "yokka", "よっか"),
              (["5", "日"], "5日", "itsuka", "いつか"),
              (["6", "日"], "6日", "muika", "むいか"),
              (["7", "日"], "7日", "nanoka", "なのか"),
              (["8", "日"], "8日", "youka", "ようか"),
              (["9", "日"], "9日", "kokonoka", "ここのか"),
              (["10", "日"], "10日", "tooka", "とおか"),
              (["14", "日"], "14日", "juuyokka", "じゅうよっか"),
              (["20", "日"], "20日", "hatsuka", "はつか"),
              (["24", "日"], "24日", "nijuuyokka", "にじゅうよっか")
          ])
    func irregularDigitDates(surfaces: [String], text: String, romaji: String, furigana: String) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: [String?](repeating: nil, count: surfaces.count - 1) + ["にち"]))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("fuses 六 plainly before 歳 (roku exception → plain fusion)")
    func rokuExceptionBeforeSai() throws {
        let annotator = makeAnnotator(tokens(
            ["六", "歳"], readings: ["ろく", "さい"]
        ))

        let segments = try #require(annotator.segments(for: "六歳"))

        #expect(describe(segments) == [["六歳", "rokusai", "ろくさい"]])
    }

    @Test("fuses the digit 6 plainly before 歳 (roku exception → plain fusion)")
    func rokuExceptionDigitBeforeSai() throws {
        let annotator = makeAnnotator(tokens(
            ["6", "歳"], readings: [nil, "さい"]
        ))

        let segments = try #require(annotator.segments(for: "6歳"))

        #expect(describe(segments) == [["6歳", "rokusai", "ろくさい"]])
    }

    @Test("accumulates consecutive kanji numerals into one run (千 is itself a numeral)")
    func senAccumulatesIntoTheNumberRun() throws {
        let annotator = makeAnnotator(tokens(
            ["六", "千"], readings: ["ろく", "せん"]
        ))

        let segments = try #require(annotator.segments(for: "六千"))

        #expect(describe(segments) == [["六千", "rokusen", "ろくせん"]])
    }

    @Test("fuses 六 plainly before the とう reading of 等 (roku exception → plain fusion)")
    func rokuExceptionBeforeTou() throws {
        let annotator = makeAnnotator(tokens(
            ["六", "等"], readings: ["ろく", "とう"]
        ))

        let segments = try #require(annotator.segments(for: "六等"))

        #expect(describe(segments) == [["六等", "rokutou", "ろくとう"]])
    }

    @Test("fuses plainly before a ば行 counter (一番/十番/六番/八番)",
          arguments: [
              (["一", "番"], ["いち", "ばん"], "一番", "ichiban", "いちばん"),
              (["十", "番"], ["じゅう", "ばん"], "十番", "juuban", "じゅうばん"),
              (["六", "番"], ["ろく", "ばん"], "六番", "rokuban", "ろくばん"),
              (["八", "番"], ["はち", "ばん"], "八番", "hachiban", "はちばん")
          ])
    func voicedOnsetFusesPlainReading(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("reads the irregular people counter as one fused word (一人/二人/四人)",
          arguments: [
              (["一", "人"], ["いち", "にん"], "一人", "hitori", "ひとり"),
              (["二", "人"], ["に", "にん"], "二人", "futari", "ふたり"),
              (["四", "人"], ["よん", "にん"], "四人", "yonin", "よにん")
          ])
    func irregularPeopleCounterFusion(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("fuses Arabic digits with the irregular people counter (2人 → futari)")
    func digitPeopleCounterFusion() throws {
        let annotator = makeAnnotator(tokens(
            ["2", "人"], readings: [nil, "にん"]
        ))

        let segments = try #require(annotator.segments(for: "2人"))

        #expect(describe(segments) == [["2人", "futari", "ふたり"]])
    }

    @Test("fuses regular people counters plainly (三人/十人)",
          arguments: [
              (["三", "人"], ["さん", "にん"], "三人", "sannin", "さんにん"),
              (["十", "人"], ["じゅう", "にん"], "十人", "juunin", "じゅうにん")
          ])
    func regularPeopleCounterFusesPlainly(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("fuses 本 with its forced counter reading and ん-voicing (三万本 → sanmanbon)")
    func voicedHon() throws {
        let annotator = makeAnnotator(tokens(
            ["三", "万", "本"], readings: ["さん", "まん", "ほん"]
        ))

        let segments = try #require(annotator.segments(for: "三万本"))

        #expect(describe(segments) == [["三万本", "sanmanbon", "さんまんぼん"]])
    }

    @Test("flushes the held-back number before punctuation (三、四本)")
    func flushBeforePunctuation() throws {
        let annotator = makeAnnotator(tokens(
            ["三", "、", "四", "本"], readings: ["さん", "、", "よん", "ほん"]
        ))

        let segments = try #require(annotator.segments(for: "三、四本"))

        #expect(describe(segments) == [
            ["三", "san", "さん"], ["、", "、", nil], ["四本", "yonbon", "よんぼん"]
        ])
    }

    @Test("fuses 年 into the resolved number (2年 → ninen)")
    func yearAfterDigits() throws {
        let annotator = makeAnnotator(tokens(
            ["2", "年"], readings: [nil, "ねん"]
        ))

        let segments = try #require(annotator.segments(for: "2年"))

        #expect(describe(segments) == [["2年", "ninen", "にねん"]])
    }

    @Test("fuses 年 into a kanji numeral (八年 → hachinen)")
    func yearAfterKanjiNumeral() throws {
        let annotator = makeAnnotator(tokens(
            ["八", "年"], readings: ["はち", "ねん"]
        ))

        let segments = try #require(annotator.segments(for: "八年"))

        #expect(describe(segments) == [["八年", "hachinen", "はちねん"]])
    }

    @Test("reads 年 as the counter after unresolved digits (2026年)")
    func yearAfterUnresolvedDigits() throws {
        let annotator = makeAnnotator(tokens(
            ["2026", "年"], readings: [nil, "ねん"]
        ))

        let segments = try #require(annotator.segments(for: "2026年"))

        #expect(describe(segments) == [["2026", "2026", nil], ["年", "nen", "ねん"]])
    }

    @Test("leaves bare digit runs unannotated (123)")
    func bareDigitsUnannotated() throws {
        let annotator = makeAnnotator(tokens(
            ["123"], readings: [nil]
        ))

        let segments = try #require(annotator.segments(for: "123"))

        #expect(describe(segments) == [["123", "123", nil]])
    }

    @Test("geminate-fuses kanji-numeral token pairs the engine emits (十回, 一着, 八分)",
          arguments: [
              (["十", "回"], ["じゅう", "かい"], "十回", "jukkai", "じゅっかい"),
              (["一", "着"], ["いち", "ちゃく"], "一着", "icchaku", "いっちゃく"),
              (["八", "分"], ["はち", "ふん"], "八分", "happun", "はっぷん")
          ])
    func kanjiCounterPairFusion(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("accumulates digits with a following kanji numeral (3万 → sanman)")
    func mixedAccumulation() throws {
        let annotator = makeAnnotator(tokens(
            ["3", "万"], readings: [nil, "まん"]
        ))

        let segments = try #require(annotator.segments(for: "3万"))

        #expect(describe(segments) == [["3万", "sanman", "さんまん"]])
    }

    @Test("resolves a digit run before a kanji numeral (3千 → sansen)")
    func digitRunBeforeKanjiNumeral() throws {
        let annotator = makeAnnotator(tokens(
            ["3", "千"], readings: [nil, "せん"]
        ))

        let segments = try #require(annotator.segments(for: "3千"))

        #expect(describe(segments) == [["3千", "sansen", "さんせん"]])
    }

    @Test("stays unannotated when a numeral after digits has no reading (1千)")
    func unreadableKanjiNumeralAfterDigits() throws {
        let annotator = makeAnnotator(tokens(
            ["1", "千"], readings: [nil, nil]
        ))

        let segments = try #require(annotator.segments(for: "1千"))

        #expect(describe(segments) == [["1千", "1千", nil]])
    }

    @Test("flushes a trailing held-back number as its own segment (六)")
    func trailingNumberFlushes() throws {
        let annotator = makeAnnotator(tokens(
            ["六"], readings: ["ろく"]
        ))

        let segments = try #require(annotator.segments(for: "六"))

        #expect(describe(segments) == [["六", "roku", "ろく"]])
    }

    // MARK: - ASR whitespace

    @Test("fuses across ASR whitespace between number and counter (2 人 → futari)")
    func whitespaceTolerantPeopleFusion() throws {
        let annotator = makeAnnotator(spacedTokens(
            ["2", "人"], readings: [nil, "にん"]
        ))

        let segments = try #require(annotator.segments(for: "2 人"))

        #expect(describe(segments) == [["2 人", "futari", "ふたり"]])
    }

    @Test("fuses spaced dates segment-wise with the space re-emitted (9 月 10 日 → kugatsu tooka)")
    func spacedDateFusion() throws {
        let annotator = makeAnnotator(spacedTokens(
            ["9", "月", "10", "日"], readings: [nil, "つき", nil, "にち"]
        ))

        let segments = try #require(annotator.segments(for: "9 月 10 日"))

        #expect(describe(segments) == [
            ["9 月", "kugatsu", "くがつ"], [" ", " ", nil], ["10 日", "tooka", "とおか"]
        ])
    }

    @Test("accumulates digits across ASR whitespace (3 万 → sanman)")
    func whitespaceBetweenNumeralsAccumulates() throws {
        let annotator = makeAnnotator(spacedTokens(
            ["3", "万"], readings: [nil, "まん"]
        ))

        let segments = try #require(annotator.segments(for: "3 万"))

        #expect(describe(segments) == [["3 万", "sanman", "さんまん"]])
    }

    @Test("flushes a held number before a hiragana token, re-emitting the space (2 は → ni wa)")
    func whitespaceBeforeParticleFlushes() throws {
        let annotator = makeAnnotator(spacedTokens(
            ["2", "は"], readings: [nil, "は"]
        ))

        let segments = try #require(annotator.segments(for: "2 は"))

        #expect(describe(segments) == [["2", "ni", nil], [" ", " ", nil], ["は", "wa", nil]])
    }

    // MARK: - Plain fusion

    @Test("fuses non-geminating numbers plainly with the counter (一度/二階/十台)",
          arguments: [
              (["一", "度"], ["いち", "ど"], "一度", "ichido", "いちど"),
              (["二", "階"], ["に", "かい"], "二階", "nikai", "にかい"),
              (["十", "台"], ["じゅう", "だい"], "十台", "juudai", "じゅうだい")
          ])
    func plainFusion(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("reads the lexical month numbers (4月/7月/9月; regular months stay plain)",
          arguments: [
              (["4", "月"], "4月", "shigatsu", "しがつ"),
              (["7", "月"], "7月", "shichigatsu", "しちがつ"),
              (["9", "月"], "9月", "kugatsu", "くがつ"),
              (["3", "月"], "3月", "sangatsu", "さんがつ"),
              (["10", "月"], "10月", "juugatsu", "じゅうがつ")
          ])
    func monthCounterReadings(
        surfaces: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: [nil, "つき"]))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("reads the lexical hour numbers (4時/7時/9時; regular hours stay plain)",
          arguments: [
              (["4", "時"], "4時", "yoji", "よじ"),
              (["7", "時"], "7時", "shichiji", "しちじ"),
              (["9", "時"], "9時", "kuji", "くじ"),
              (["1", "時"], "1時", "ichiji", "いちじ"),
              (["3", "時"], "3時", "sanji", "さんじ")
          ])
    func hourCounterReadings(
        surfaces: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: [nil, "とき"]))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("voices a は行 counter across a moraic ん (3分/4分/3匹/2分)",
          arguments: [
              (["3", "分"], "3分", "sanpun", "さんぷん"),
              (["4", "分"], "4分", "yonpun", "よんぷん"),
              (["3", "匹"], "3匹", "sanbiki", "さんびき"),
              (["2", "分"], "2分", "nifun", "にふん")
          ])
    func voicedCounterAcrossN(
        surfaces: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(
            surfaces, readings: [nil, surfaces[1] == "分" ? "ふん" : "ひき"]
        ))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    // MARK: - Lexical reading repairs

    @Test("repairs the dictionary's unvoiced reading of the entrance to the spoken rendaku form",
          arguments: [
              ("入口", "iriguchi", "いりぐち"),
              ("入り口", "iriguchi", "いりぐち")
          ])
    func entranceRendakuRepair(text: String, romaji: String, furigana: String) throws {
        let annotator = makeAnnotator([token(text, start: 0, reading: "いりくち")])

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }
}
