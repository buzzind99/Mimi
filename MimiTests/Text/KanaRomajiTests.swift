@testable import Mimi
import Testing

/// Tests the kana → wapuro-romaji conversion through the public
/// `KanaRomaji.romaji(fromKana:)` entry point. Expected values are the
/// romaji strings the annotation suite pins (see `ReadingAnnotatorTests`);
/// the legacy-corpus parameterization doubles as the round-trip spot check
/// `KanaRomaji(legacy furigana/kana reading) == legacy romaji` for the
/// shared counter/date/honorific corpus.
@Suite("Kana → romaji conversion")
struct KanaRomajiTests {

    // MARK: - Plain morae

    @Test("maps plain morae to their romaji spellings", arguments: [
        ("さくら", "sakura"),
        ("あいうえお", "aiueo"),
        ("し", "shi"),
        ("ち", "chi"),
        ("つ", "tsu"),
        ("ひと", "hito"),
        ("を", "wo"),
        ("サクラ", "sakura"),
        ("ヴ", "vu")
    ])
    func plainMorae(kana: String, expected: String) {
        #expect(KanaRomaji.romaji(fromKana: kana) == expected)
    }

    // MARK: - Digraphs

    @Test("maps y-digraphs and foreign forms to their spellings", arguments: [
        ("しゃ", "sha"),
        ("りゃ", "rya"),
        ("ぴょ", "pyo"),
        ("ファ", "fa"),
        ("ヴァ", "va"),
        ("ティ", "ti"),
        ("とぅ", "tu"),
        ("ウォ", "wo"),
    ])
    func digraphs(kana: String, expected: String) {
        #expect(KanaRomaji.romaji(fromKana: kana) == expected)
    }

    // MARK: - Long vowels

    @Test("keeps long vowels mora-by-mora and repeats choonpu vowels", arguments: [
        ("とう", "tou"),
        ("じゅう", "juu"),
        ("おう", "ou"),
        ("コーヒー", "koohii"),
        ("うーん", "uun"),
    ])
    func longVowels(kana: String, expected: String) {
        #expect(KanaRomaji.romaji(fromKana: kana) == expected)
    }

    /// Defensive: ん can't be prolonged, a spoken "tsu" (stranded っ) can't
    /// be prolonged either, and a leading ー has no previous vowel — all
    /// fail instead of repeating a stale mora.
    @Test("choonpu with no vowel to repeat fails the conversion", arguments: [
        ("まんー", nil as String?),
        ("っー", nil as String?),
        ("ー", nil as String?),
    ])
    func choonpuWithoutVowelFails(kana: String, expected: String?) {
        #expect(KanaRomaji.romaji(fromKana: kana) == expected)
    }

    // MARK: - Sokuon

    @Test("geminates the following consonant", arguments: [
        ("いっかい", "ikkai"),
        ("ろっぴゃく", "roppyaku"),
        ("めっちゃ", "meccha"),
        ("いっつ", "ittsu"),
        ("はっは", "happa"),
        ("はっぷん", "happun"),
        ("はっぴき", "happiki"),
        ("ベッド", "beddo"),
        ("エッジ", "ejji"),
        ("ラッパ", "rappa"),
    ])
    func sokuonGemination(kana: String, expected: String) {
        #expect(KanaRomaji.romaji(fromKana: kana) == expected)
    }

    // Defensive: no dictionary reading puts っ before a vowel or a kanji;
    // the sokuon degrades to a spoken "tsu", and the unmappable mora that
    // follows (or a trailing ー, see above) still fails the conversion.
    @Test("a stranded sokuon is spoken as standalone tsu", arguments: [
        ("おっ", "otsu"),
        ("っあ", "tsua"),
    ])
    func strandedSokuonSpeaksTsu(kana: String, expected: String) {
        #expect(KanaRomaji.romaji(fromKana: kana) == expected)
    }

    @Test("a sokuon before an unmappable mora fails the conversion")
    func sokuonBeforeUnmappableFails() {
        #expect(KanaRomaji.romaji(fromKana: "あっ漢") == nil)
    }

    @Test("a doubled vowel does not emit a sokuon")
    func doubledVowelIsNotSokuon() {
        #expect(KanaRomaji.romaji(fromKana: "おおきい") == "ookii")
    }

    // MARK: - Moraic n

    @Test("emits plain n before consonants and syllables", arguments: [
        ("さん", "san"),
        ("あんた", "anta"),
        ("かんな", "kanna"),
    ])
    func plainMoraicN(kana: String, expected: String) {
        #expect(KanaRomaji.romaji(fromKana: kana) == expected)
    }

    @Test("uses an apostrophe before vowels", arguments: [
        ("まんいん", "man'in"),
        ("げんや", "gen'ya"),
    ])
    func apostropheBeforeVowel(kana: String, expected: String) {
        #expect(KanaRomaji.romaji(fromKana: kana) == expected)
    }

    @Test("writes doubled n before vowel-initial syllables", arguments: [
        ("あんない", "annai"),
        ("さんにん", "sannin"),
    ])
    func doubledN(kana: String, expected: String) {
        #expect(KanaRomaji.romaji(fromKana: kana) == expected)
    }

    /// The converter is context-free: は maps to "ha"; the particle
    /// reading ("wa") is the annotator's override.
    @Test("maps は to its historical spelling")
    func haIsContextFree() {
        #expect(KanaRomaji.romaji(fromKana: "こんにちは") == "konnichiha")
    }

    // MARK: - Historical voiced kana

    @Test("voices づ and ぢ in words", arguments: [
        ("つづり", "tsuzuri"),
        ("はなぢ", "hanaji"),
    ])
    func historicalVoicing(kana: String, expected: String) {
        #expect(KanaRomaji.romaji(fromKana: kana) == expected)
    }

    // MARK: - Legacy corpus round-trip

    @Test("matches the legacy counter/date/honorific corpus", arguments: [
        ("いっぽん", "ippon"),
        ("はっさい", "hassai"),
        ("よっか", "yokka"),
        ("はたち", "hatachi"),
        ("かあさん", "kaasan"),
        ("おかあさま", "okaasama"),
        ("おかあさん", "okaasan"),
        ("じゅっかい", "jukkai"),
        ("みっか", "mikka"),
        ("いって", "itte"),
        ("ときどき", "tokidoki"),
        ("いっち", "icchi"),
        ("はは", "haha"),
    ])
    func legacyCorpus(kana: String, expected: String) {
        #expect(KanaRomaji.romaji(fromKana: kana) == expected)
    }

    // MARK: - Unmappable input

    @Test("returns nil for empty, digit, and unmappable input", arguments: [
        ("", nil as String?),
        ("123", nil as String?),
        ("くら3ね", nil as String?),
        ("テスト漢字", nil as String?),
        ("あん漢", nil as String?),
    ])
    func unmappableInput(kana: String, expected: String?) {
        #expect(KanaRomaji.romaji(fromKana: kana) == expected)
    }

    // MARK: - Normalization

    @Test("composes decomposed voicing marks before mapping")
    func decomposedVoicingMark() {
        // か + combining voiced sound mark must behave like precomposed が.
        let decomposedGaku = "か\u{3099}く"

        #expect(KanaRomaji.romaji(fromKana: decomposedGaku) == "gaku")
    }
}
