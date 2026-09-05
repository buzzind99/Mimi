import Foundation
@testable import Mimi
import Testing

// MARK: - Live dictionary corpus

/// Annotations pinned against the real IPADIC model (live tokenizer
/// runtime): one surface-walking reading per token, MeCab morpheme-level
/// segmentation (conjugated verbs split into stem + ending). The shared
/// `LiveDictionaryRuntime`
/// backs the suite (prepared dictionary, else the fetched model decompressed
/// once into a temp file).
@Suite("ReadingAnnotator dictionary corpus", .enabled(if: LiveDictionaryRuntime.isAvailable))
struct ReadingAnnotatorLiveTests {

    private static let annotator = ReadingAnnotator(tokenize: {
        LiveDictionaryRuntime.engine?.tokenize($0)
    })

    private func segments(_ text: String) throws -> [ReadingSegment] {
        try #require(Self.annotator.segments(for: text))
    }

    // MARK: conjugations — the migration's payoff

    @Test("conjugated verbs annotate with surface readings (MeCab segmentation)")
    func conjugatedSurfaceReadings() throws {
        let segments = try segments("食べました")

        #expect(describe(segments) == [
            ["食べ", "tabe", "たべ"], ["まし", "mashi", nil], ["た", "ta", nil]
        ])
    }

    @Test("the negative-continuous form walks its surface (言ってない)",
          arguments: [
              ("見た", [["見", "mi", "み"], ["た", "ta", nil]]),
              ("言ってない", [["言って", "itte", "いって"], ["ない", "nai", nil]]),
              ("分かってない", [["分かって", "wakatte", "わかって"], ["ない", "nai", nil]]),
              ("来てない", [["来", "ki", "き"], ["て", "te", nil], ["ない", "nai", nil]])
          ])
    func surfaceWalkingConjugations(input: String, expected: [[String?]]) throws {
        let segments = try segments(input)

        #expect(describe(segments) == expected)
    }

    @Test("geminate-fuses the stem-final sokuon with the auxiliary (高かった → takakatta)")
    func stemFinalSokuon() throws {
        let segments = try segments("高かった")

        #expect(describe(segments) == [
            ["高かった", "takakatta", "たかかった"]
        ])
    }

    // MARK: single-word readings

    @Test("kanji words carry their IPADIC reading as romaji and furigana", arguments: [
        ("桜", "sakura", "さくら"),
        ("時々", "tokidoki", "ときどき"),
        ("案内", "annai", "あんない"),
        ("一致", "icchi", "いっち"),
        ("一回", "ikkai", "いっかい"),
        ("一着", "icchaku", "いっちゃく"),
        ("八分", "happun", "はっぷん"),
        ("八歳", "hassai", "はっさい"),
        ("600回", "roppyakkai", "ろっぴゃっかい"),
        ("私", "watashi", "わたし"),
        ("お母さん", "okaasan", "おかあさん"),
        ("母さん", "kaasan", "かあさん"),
        ("お父さん", "otousan", "おとうさん"),
        ("お母ちゃん", "okaachan", "おかあちゃん"),
        ("お母様", "okaasama", "おかあさま"),
        ("抹茶", "matcha", "まっちゃ"),
        ("こんにちは", "konnichiwa", nil),
        ("こんばんは", "konbanwa", nil),
        ("それでは", "soredewa", nil),
        ("では", "dewa", nil),
        ("または", "matawa", nil),
        ("かんな", "kanna", nil),
        ("めっちゃ", "meccha", nil),
        ("ヴァイオリン", "vaiorin", nil)
    ])
    func dictionaryReading(input: String, romaji: String, furigana: String?) throws {
        let segments = try segments(input)

        #expect(describe(segments) == [[input, romaji, furigana]])
    }

    // MARK: particles

    @Test("reads the directional particle as e")
    func directionalParticle() throws {
        let segments = try segments("学校へ行く")

        #expect(describe(segments) == [
            ["学校", "gakkou", "がっこう"], ["へ", "e", nil], ["行く", "iku", "いく"]
        ])
    }

    @Test("reads the topic particle as wa")
    func topicParticle() throws {
        let segments = try segments("は")

        #expect(describe(segments) == [["は", "wa", nil]])
    }

    @Test("reads the object particle mid-sentence as o")
    func objectParticle() throws {
        let segments = try segments("動画を見ます。")

        #expect(describe(segments) == [
            ["動画", "douga", "どうが"], ["を", "o", nil],
            ["見", "mi", "み"], ["ます", "masu", nil], ["。", "。", nil]
        ])
    }

    @Test("reads the segmented で+は context through the particle override (ならでは)")
    func segmentedDewaContext() throws {
        let segments = try segments("ならでは")

        #expect(describe(segments) == [["なら", "nara", nil], ["では", "dewa", nil]])
    }

    // MARK: counters

    @Test("geminate-fuses the 十+回 token pair (じゅっかい; じっかい is equally valid)")
    func tenCounter() throws {
        let segments = try segments("十回")

        #expect(describe(segments) == [["十回", "jukkai", "じゅっかい"]])
    }

    @Test("reads irregular kanji-numeral days as one fused word (二日/三日/四日/七日)",
          arguments: [
              ("二日", "futsuka", "ふつか"),
              ("三日", "mikka", "みっか"),
              ("四日", "yokka", "よっか"),
              ("七日", "nanoka", "なのか")
          ])
    func irregularKanjiDays(input: String, romaji: String, furigana: String) throws {
        let segments = try segments(input)

        #expect(describe(segments) == [[input, romaji, furigana]])
    }

    @Test("fuses 二十日 with the irregular day reading (はつか → hatsuka)")
    func hatsukaFuses() throws {
        let segments = try segments("二十日")

        #expect(describe(segments) == [["二十日", "hatsuka", "はつか"]])
    }

    @Test("fuses 二十歳 with the geminated counter (にじゅっさい; はたち is lost — documented)")
    func nijussai() throws {
        let segments = try segments("二十歳")

        #expect(describe(segments) == [["二十歳", "nijussai", "にじゅっさい"]])
    }

    @Test("fuses 十四日 with the irregular day reading (じゅうよっか)")
    func juuyokkaFuses() throws {
        let segments = try segments("十四日")

        #expect(describe(segments) == [["十四日", "juuyokka", "じゅうよっか"]])
    }

    @Test("fuses 本 with the forced counter reading, voicing across ん (二本/三本)",
          arguments: [
              ("二本", "nihon", "にほん"),
              ("三本", "sanbon", "さんぼん")
          ])
    func fusedHon(input: String, romaji: String, furigana: String) throws {
        let segments = try segments(input)

        #expect(describe(segments) == [[input, romaji, furigana]])
    }

    @Test("fuses 六 plainly before 歳 (roku exception → plain fusion)")
    func rokuBeforeSai() throws {
        let segments = try segments("六歳")

        #expect(describe(segments) == [["六歳", "rokusai", "ろくさい"]])
    }

    @Test("fuses 六 plainly before 等 with its counter reading とう (the old suite pinned the standalone など reading)")
    func rokuBeforeTou() throws {
        let segments = try segments("六等")

        #expect(describe(segments) == [["六等", "rokutou", "ろくとう"]])
    }

    @Test("fuses 七 plainly before 回 with its dictionary reading なな (old suite pinned the heuristics' nana)")
    func sevenCounter() throws {
        let segments = try segments("七回")

        #expect(describe(segments) == [["七回", "nanakai", "ななかい"]])
    }

    @Test("reads the irregular people counter as one fused word (一人/二人/四人)",
          arguments: [
              ("一人", "hitori", "ひとり"),
              ("二人", "futari", "ふたり"),
              ("四人", "yonin", "よにん")
          ])
    func irregularPeopleCounter(input: String, romaji: String, furigana: String) throws {
        let segments = try segments(input)

        #expect(describe(segments) == [[input, romaji, furigana]])
    }

    @Test("fuses regular people counters plainly (三人/十人)",
          arguments: [
              ("三人", "sannin", "さんにん"),
              ("十人", "juunin", "じゅうにん")
          ])
    func regularPeopleCounter(input: String, romaji: String, furigana: String) throws {
        let segments = try segments(input)

        #expect(describe(segments) == [[input, romaji, furigana]])
    }

    @Test("fuses Arabic digits with a counter via the digit table (600回)")
    func digitCounter() throws {
        let segments = try segments("600回")

        #expect(describe(segments) == [["600回", "roppyakkai", "ろっぴゃっかい"]])
    }

    @Test("fuses the voiced counter run with 本 (三万本 → sanmanbon)")
    func voicedHon() throws {
        let segments = try segments("三万本")

        #expect(describe(segments) == [["三万本", "sanmanbon", "さんまんぼん"]])
    }

    @Test("flushes the held-back number before punctuation (三、四本; old suite pinned the split 四/本)")
    func flushedNumberBeforePunctuation() throws {
        let segments = try segments("三、四本")

        #expect(describe(segments) == [
            ["三", "san", "さん"], ["、", "、", nil], ["四本", "yonbon", "よんぼん"]
        ])
    }

    @Test("leaves bare digit runs unannotated (123)")
    func bareDigits() throws {
        let segments = try segments("123")

        #expect(describe(segments) == [["123", "123", nil]])
    }

    // MARK: 年

    @Test("fuses 年 into the number (2年 → ninen)")
    func yearAfterDigits() throws {
        let segments = try segments("2年")

        #expect(describe(segments) == [["2年", "ninen", "にねん"]])
    }

    @Test("fuses 年 into a kanji numeral (八年 → hachinen)")
    func yearAfterKanjiNumeral() throws {
        let segments = try segments("八年")

        #expect(describe(segments) == [["八年", "hachinen", "はちねん"]])
    }

    // MARK: family honorifics

    @Test("keeps the honorific fusion after a leading interjection (お、母さん)")
    func honorificAfterPunctuation() throws {
        let segments = try segments("お、母さん")

        #expect(describe(segments) == [
            ["お", "o", nil], ["、", "、", nil], ["母さん", "kaasan", "かあさん"]
        ])
    }

    @Test("keeps the headword reading when punctuation interrupts the term (母、さん)")
    func punctuatedFamilyTerm() throws {
        let segments = try segments("母、さん")

        #expect(describe(segments) == [
            ["母", "haha", "はは"], ["、", "、", nil], ["さん", "san", nil]
        ])
    }

    @Test("keeps the headword reading outside honorifics (私の母です)")
    func familyInContext() throws {
        let segments = try segments("私の母です")

        #expect(describe(segments) == [
            ["私", "watashi", "わたし"], ["の", "no", nil],
            ["母", "haha", "はは"], ["です", "desu", nil]
        ])
    }

    @Test("splits honorifics the dictionary prefixes separately (お姉さん/お兄さん/御母さん/祖父さん)",
          arguments: [
              ("お姉さん", [["お", "o", nil], ["姉さん", "neesan", "ねえさん"]]),
              ("お兄さん", [["お", "o", nil], ["兄さん", "niisan", "にいさん"]]),
              ("御母さん", [["御", "go", "ご"], ["母さん", "kaasan", "かあさん"]]),
              ("祖父さん", [["祖父", "sofu", "そふ"], ["さん", "san", nil]])
          ])
    func splitHonorifics(input: String, expected: [[String?]]) throws {
        let segments = try segments(input)

        #expect(describe(segments) == expected)
    }

    // MARK: demonstratives and names

    @Test("reads 方 with its dictionary reading ほう (old suite pinned the person reading かた)",
          arguments: [
              ("あの方", [["あの", "ano", nil], ["方", "hou", "ほう"]]),
              ("この方", [["この", "kono", nil], ["方", "hou", "ほう"]]),
              ("その方", [["その", "sono", nil], ["方", "hou", "ほう"]]),
              ("こっちの方", [["こっち", "kocchi", nil], ["の", "no", nil], ["方", "hou", "ほう"]])
          ])
    func houReading(input: String, expected: [[String?]]) throws {
        let segments = try segments(input)

        #expect(describe(segments) == expected)
    }

    @Test("splits その方がいい without the がいい artifact (MeCab segmentation)")
    func ambiguousKata() throws {
        let segments = try segments("その方がいい")

        #expect(describe(segments) == [
            ["その", "sono", nil], ["方", "hou", "ほう"], ["が", "ga", nil], ["いい", "ii", nil]
        ])
    }

    /// Names beyond IPADIC's person-name list still degrade to unknown —
    /// JMnedict proper-noun coverage is out of scope.
    @Test("annotates the name with its IPADIC person-name entry (田中さん; old suite degraded per-kanji)")
    func nameAnnotates() throws {
        let segments = try segments("田中さん")

        #expect(describe(segments) == [["田中", "tanaka", "たなか"], ["さん", "san", nil]])
    }

    @Test("splits いい天気 into the adjective + noun (MeCab segmentation)")
    func iitenkiSplits() throws {
        let segments = try segments("いい天気")

        #expect(describe(segments) == [["いい", "ii", nil], ["天気", "tenki", "てんき"]])
    }

    @Test("splits 私達 into the pronoun + suffix (MeCab segmentation)")
    func watashitachiSplits() throws {
        let segments = try segments("私達")

        #expect(describe(segments) == [["私", "watashi", "わたし"], ["達", "tachi", "たち"]])
    }

    // MARK: sokuons and interjections

    @Test("annotates the stem + auxiliary chain (言ってあげる; the old suite deinflected to いう)")
    func stemPlusAuxiliary() throws {
        let segments = try segments("言ってあげる")

        #expect(describe(segments) == [
            ["言って", "itte", "いって"], ["あげる", "ageru", nil]
        ])
    }

    @Test("keeps the spoken-tsu fallback for the stranded sokuon (おっ → otsu)")
    func spokenTsuFallback() throws {
        let segments = try segments("おっ、いいね")

        #expect(describe(segments) == [
            ["おっ", "otsu", nil], ["、", "、", nil], ["いい", "ii", nil], ["ね", "ne", nil]
        ])
    }

    @Test("annotates the stem-final sokuon (そう言っ; romaji reads the isolated いっ as itsu — the KanaRomaji spoken-tsu convention)")
    func trailingSokuonStem() throws {
        let segments = try segments("そう言っ")

        #expect(describe(segments) == [["そう", "sou", nil], ["言っ", "itsu", "いっ"]])
    }

    @Test("geminate-chains whitespace-separated sokuon tokens into one segment (ASR word spacing: なっ ちゃっ てる)")
    func whitespaceSokuonChain() throws {
        let segments = try segments("なっ ちゃっ てる")

        #expect(describe(segments) == [["なっ ちゃっ てる", "nacchatteru", nil]])
    }

    // MARK: Latin and rare forms

    @Test("self-transcribes a Latin run as one unknown token (Hello; old suite split per character)")
    func latinRun() throws {
        let segments = try segments("Hello")

        #expect(describe(segments) == [["Hello", "Hello", nil]])
    }

    @Test("keeps whitespace as its own plain segment (A B)")
    func whitespaceSegment() throws {
        let segments = try segments("A B")

        #expect(describe(segments) == [["A", "A", nil], [" ", " ", nil], ["B", "B", nil]])
    }

    @Test("splits 𠮷野家 around the unmodeled ideograph")
    func rareKanjiCompound() throws {
        let segments = try segments("𠮷野家")

        #expect(describe(segments) == [["𠮷", "𠮷", nil], ["野家", "noya", "のや"]])
    }

    @Test("self-transcribes a rare ideograph without an entry (㐂)")
    func extAIdeograph() throws {
        let segments = try segments("㐂")

        #expect(describe(segments) == [["㐂", "㐂", nil]])
    }

    @Test("self-transcribes an unmatched kanji (𠮷)")
    func rareKanji() throws {
        let segments = try segments("𠮷")

        #expect(describe(segments) == [["𠮷", "𠮷", nil]])
    }

    // MARK: invariant

    @Test("surfaces concatenate back to the input", arguments: [
        "今日はいい天気ですね。", "動画を見ます。", "学校へ行く", "一回", "600回", "八歳",
        "三万本", "二十日", "二十歳", "お母さん", "食べました", "見た", "言ってない", "来てない",
        "高かった", "田中さん", "A B", "𠮷野家", "そう言っ", "は", "を", "私達", "その方がいい",
        "こんにちは", "123", "お、母さん", "母、さん", "私の母です", "六等", "六歳", "七回",
        "2年", "八年", "十四日", "おっ、いいね", "言ってあげる", "こっちの方", "㐂", "𠮷", "Hello",
        "一人", "二人", "四人", "一人前", "それでは", "ならでは",
        "なっ ちゃっ てる", "ドライブでてないかも なんか 新規の トライブ 作成 になっ ちゃっ てるなぁ。"
    ])
    func concatenateBack(text: String) throws {
        let segments = try segments(text)

        #expect(segments.map(\.surface).joined() == text)
    }
}
