import Foundation
@testable import Mimi
import Testing

// MARK: - Live dictionary corpus

/// Resolves the live dictionary runtime for the corpus suite from the store's
/// prepared dictionary (`DictionaryStore.resolve()` — first launch or
/// `MIMI_DICT`). Interim during the vibrato migration: the suite stays
/// skipped until a dictionary is prepared, and its expectations are
/// regenerated for the new surface-reading payload in Phase 4.
enum LiveDictionary {
    static let engine: DictionaryEngine? = {
        guard let ffi = DictionaryFFI.load() else { return nil }
        guard let resolved = DictionaryStore.resolve() else { return nil }
        return DictionaryEngine(ffi: ffi, resolveDictionary: { resolved })
    }()

    static var isAvailable: Bool {
        engine != nil
    }
}

/// Annotations pinned against the real JMdict database.
@Suite("ReadingAnnotator dictionary corpus", .enabled(if: LiveDictionary.isAvailable))
struct ReadingAnnotatorLiveTests {

    private static let annotator = ReadingAnnotator(tokenize: {
        LiveDictionary.engine?.tokenize($0)
    })

    private func segments(_ text: String) throws -> [ReadingSegment] {
        try #require(Self.annotator.segments(for: text))
    }

    // MARK: single-word readings

    @Test("kanji words carry their JMdict reading as romaji and furigana", arguments: [
        ("桜", "sakura", "さくら"),
        ("時々", "tokidoki", "ときどき"),
        ("案内", "annai", "あんない"),
        ("一致", "icchi", "いっち"),
        ("一回", "ikkai", "いっかい"),
        ("二日", "futsuka", "ふつか"),
        ("三日", "mikka", "みっか"),
        ("四日", "yokka", "よっか"),
        ("七日", "nanoka", "なのか"),
        ("二十日", "hatsuka", "はつか"),
        ("二十歳", "hatachi", "はたち"),
        ("十四日", "juuyokka", "じゅうよっか"),
        ("一着", "icchaku", "いっちゃく"),
        ("八分", "happun", "はっぷん"),
        ("二本", "nihon", "にほん"),
        ("三本", "sanbon", "さんぼん"),
        ("いい天気", "iitenki", "いいてんき"),
        ("八歳", "hassai", "はっさい"),
        ("600回", "roppyakkai", "ろっぴゃっかい"),
        ("食べました", "taberu", "たべる"),
        ("高かった", "takai", "たかい"),
        ("私", "watashi", "わたし"),
        ("私達", "watashitachi", "わたしたち"),
        ("お母さん", "okaasan", "おかあさん"),
        ("母さん", "kaasan", "かあさん"),
        ("お父さん", "otousan", "おとうさん"),
        ("お姉さん", "oneesan", "おねえさん"),
        ("お兄さん", "oniisan", "おにいさん"),
        ("お母ちゃん", "okaachan", "おかあちゃん"),
        ("お母様", "okaasama", "おかあさま"),
        ("御母さん", "okaasan", "おかあさん"),
        ("祖父さん", "jiisan", "じいさん"),
        ("祖母さん", "baasan", "ばあさん"),
        ("あの方", "anokata", "あのかた"),
        ("この方", "konokata", "このかた"),
        ("その方", "sonokata", "そのかた"),
        ("抹茶", "matcha", "まっちゃ"),
        ("こんにちは", "konnichiwa", nil),
        ("こんばんは", "konbanwa", nil),
        ("かんな", "kanna", nil),
        ("めっちゃ", "meccha", nil),
        ("ヴァイオリン", "vaiorin", nil),
        ("𠮷野家", "yoshinoya", "よしのや")
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
            ["見ます", "miru", "みる"], ["。", "。", nil]
        ])
    }

    // MARK: counters

    @Test("keeps the dictionary's first reading for the fused 十回 (じっかい; both readings valid — the old suite pinned the heuristics' jukkai)")
    func tenCounter() throws {
        let segments = try segments("十回")

        #expect(describe(segments) == [["十回", "jikkai", "じっかい"]])
    }

    @Test("keeps 六 separate before 歳 (roku exception)")
    func rokuBeforeSai() throws {
        let segments = try segments("六歳")

        #expect(describe(segments) == [["六", "roku", "ろく"], ["歳", "sai", "さい"]])
    }

    @Test("keeps 六 separate before 等, whose greedy match reads など (old suite pinned the heuristics' tou)")
    func rokuBeforeTou() throws {
        let segments = try segments("六等")

        #expect(describe(segments) == [["六", "roku", "ろく"], ["等", "nado", "など"]])
    }

    @Test("keeps 七 separate before 回 with its JMdict reading しち (old suite pinned the heuristics' nana)")
    func sevenCounter() throws {
        let segments = try segments("七回")

        #expect(describe(segments) == [["七", "shichi", "しち"], ["回", "kai", "かい"]])
    }

    @Test("fuses 八 with 歳 (hassai)")
    func eightBeforeSai() throws {
        let segments = try segments("八歳")

        #expect(describe(segments) == [["八歳", "hassai", "はっさい"]])
    }

    @Test("fuses Arabic digits with a counter via the digit table (600回)")
    func digitCounter() throws {
        let segments = try segments("600回")

        #expect(describe(segments) == [["600回", "roppyakkai", "ろっぴゃっかい"]])
    }

    @Test("groups the voiced counter run before 本 (三万本 → sanman bon)")
    func voicedHon() throws {
        let segments = try segments("三万本")

        #expect(describe(segments) == [["三万", "sanman", "さんまん"], ["本", "bon", "ほん"]])
    }

    @Test("flushes a held-back number before punctuation (三、四本)")
    func flushedNumberBeforePunctuation() throws {
        let segments = try segments("三、四本")

        #expect(describe(segments) == [
            ["三", "san", "さん"], ["、", "、", nil], ["四本", "yonhon", "よんほん"]
        ])
    }

    @Test("leaves bare digit runs unannotated (123)")
    func bareDigits() throws {
        let segments = try segments("123")

        #expect(describe(segments) == [["123", "123", nil]])
    }

    // MARK: 年

    @Test("reads 年 as the counter after digits (2年 → ni nen)")
    func yearAfterDigits() throws {
        let segments = try segments("2年")

        #expect(describe(segments) == [["2", "ni", nil], ["年", "nen", "ねん"]])
    }

    @Test("reads 年 as the counter after a kanji numeral (八年 → hachi nen)")
    func yearAfterKanjiNumeral() throws {
        let segments = try segments("八年")

        #expect(describe(segments) == [["八", "hachi", "はち"], ["年", "nen", "ねん"]])
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

    // MARK: deinflection and sokuons

    @Test("deinflects to the dictionary-form reading, 10ten-style (言って → いう)")
    func deinflectedReading() throws {
        let segments = try segments("言ってあげる")

        #expect(describe(segments) == [["言って", "iu", "いう"], ["あげる", "ageru", nil]])
    }

    @Test("keeps the spoken-tsu fallback for the stranded sokuon (おっ → otsu)")
    func spokenTsuFallback() throws {
        let segments = try segments("おっ、いいね")

        #expect(describe(segments) == [
            ["おっ", "otsu", nil], ["、", "、", nil], ["いいね", "iine", nil]
        ])
    }

    @Test("keeps an unmatched trailing sokuon unannotated (そう言っ; the old suite pinned the heuristics' itsu)")
    func trailingSokuon() throws {
        let segments = try segments("そう言っ")

        #expect(describe(segments) == [["そう", "sou", nil], ["言", "gen", "げん"], ["っ", "っ", nil]])
    }

    // MARK: demonstratives and names

    @Test("annotates こっちの方 with the person reading of 方 (old suite pinned the heuristics' hou)")
    func directionalPerson() throws {
        let segments = try segments("こっちの方")

        #expect(describe(segments) == [
            ["こっち", "kocchi", nil], ["の", "no", nil], ["方", "kata", "かた"]
        ])
    }

    @Test("matches the greedy がいい artifact (その方がいい; 10ten shows the same split)")
    func ambiguousKata() throws {
        let segments = try segments("その方がいい")

        #expect(describe(segments) == [["その方", "sonokata", "そのかた"], ["がいい", "gaii", nil]])
    }

    @Test("degrades names to per-kanji dictionary readings (田中さん; JMnedict is out of scope)")
    func nameDegradesGracefully() throws {
        let segments = try segments("田中さん")

        #expect(describe(segments) == [["田", "ta", "た"], ["中", "naka", "なか"], ["さん", "san", nil]])
    }

    // MARK: Latin and rare forms

    @Test("splits Latin runs per character, self-transcribed (Hello)")
    func latinRun() throws {
        let segments = try segments("Hello")

        #expect(describe(segments) == [
            ["H", "H", nil], ["e", "e", nil], ["l", "l", nil], ["l", "l", nil], ["o", "o", nil]
        ])
    }

    @Test("keeps whitespace as its own plain segment (A B; old suite folded the space)")
    func whitespaceSegment() throws {
        let segments = try segments("A B")

        #expect(describe(segments) == [["A", "A", nil], [" ", " ", nil], ["B", "B", nil]])
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
        "三万本", "二十日", "お母さん", "食べました", "田中さん", "A B", "𠮷野家",
        "そう言っ", "は", "を", "私達", "その方がいい", "こんにちは", "123", "お、母さん",
        "母、さん", "私の母です", "六等", "六歳", "七回", "2年", "八年", "十四日",
        "おっ、いいね", "言ってあげる", "こっちの方", "㐂", "𠮷", "Hello"
    ])
    func concatenateBack(text: String) throws {
        let segments = try segments(text)

        #expect(segments.map(\.surface).joined() == text)
    }
}
