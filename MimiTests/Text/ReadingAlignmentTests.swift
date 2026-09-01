import Foundation
@testable import Mimi
import Testing

// MARK: - Surface/reading alignment

@Suite("ReadingAlignment")
struct ReadingAlignmentTests {

    private func runs(surface: String, reading: String) -> [ReadingAlignment.Run]? {
        ReadingAlignment.runs(surface: surface, reading: reading)
    }

    // MARK: walking readings

    @Test("splits a conjugated token into consumed stem and matched okurigana (見た/みた)")
    func conjugatedToken() {
        #expect(runs(surface: "見た", reading: "みた") == [
            ReadingAlignment.Run(surface: "見", kana: "み"),
            ReadingAlignment.Run(surface: "た", kana: "た")
        ])
    }

    @Test("kanji stems consume the reading up to the okurigana anchor (食べ/たべ)")
    func stemConsumesPrefix() {
        #expect(runs(surface: "食べ", reading: "たべ") == [
            ReadingAlignment.Run(surface: "食", kana: "た"),
            ReadingAlignment.Run(surface: "べ", kana: "べ")
        ])
    }

    @Test("pure-kanji surfaces consume the whole reading (学校/がっこう)")
    func pureKanjiSurface() {
        #expect(runs(surface: "学校", reading: "がっこう") == [
            ReadingAlignment.Run(surface: "学校", kana: "がっこう")
        ])
    }

    @Test("leading okurigana must match the reading's head (お母さん/おかあさん)")
    func leadingOkurigana() {
        #expect(runs(surface: "お母さん", reading: "おかあさん") == [
            ReadingAlignment.Run(surface: "お", kana: "お"),
            ReadingAlignment.Run(surface: "母", kana: "かあ"),
            ReadingAlignment.Run(surface: "さん", kana: "さん")
        ])
    }

    @Test("a kanji before the first anchor consumes the prefix (母さん/かあさん)")
    func kanjiBeforeFirstAnchor() {
        #expect(runs(surface: "母さん", reading: "かあさん") == [
            ReadingAlignment.Run(surface: "母", kana: "かあ"),
            ReadingAlignment.Run(surface: "さん", kana: "さん")
        ])
    }

    @Test("katakana surfaces fold onto the hiragana reading (ゲーム版/げーむばん)")
    func katakanaFolding() {
        #expect(runs(surface: "ゲーム版", reading: "げーむばん") == [
            ReadingAlignment.Run(surface: "ゲーム", kana: "げーむ"),
            ReadingAlignment.Run(surface: "版", kana: "ばん")
        ])
    }

    @Test("repeated surface kana resolve left to right (食べて/たべて)")
    func repeatedKana() {
        #expect(runs(surface: "食べて", reading: "たべて") == [
            ReadingAlignment.Run(surface: "食", kana: "た"),
            ReadingAlignment.Run(surface: "べて", kana: "べて")
        ])
    }

    @Test("consecutive kanji share one consumed run (時々/ときどき)")
    func consecutiveKanji() {
        #expect(runs(surface: "時々", reading: "ときどき") == [
            ReadingAlignment.Run(surface: "時々", kana: "ときどき")
        ])
    }

    // MARK: non-walking readings

    @Test("dictionary-form readings that overshoot the surface fail (見た/みる)")
    func dictionaryFormOvershoot() {
        #expect(runs(surface: "見た", reading: "みる") == nil)
    }

    @Test("leftover reading kana fail (食べた/たべ)")
    func leftoverReading() {
        #expect(runs(surface: "食べた", reading: "たべ") == nil)
    }

    @Test("a mismatched surface kana fails (かな/かん)")
    func mismatchedKana() {
        #expect(runs(surface: "かな", reading: "かん") == nil)
    }

    @Test("a reading containing kanji fails (漢/漢字)")
    func kanjiInReading() {
        #expect(runs(surface: "漢", reading: "漢字") == nil)
    }

    @Test("a surface containing Latin fails (AB/えーびー)")
    func latinInSurface() {
        #expect(runs(surface: "AB", reading: "えーびー") == nil)
    }

    @Test("empty surfaces and readings fail", arguments: [("", "み"), ("見", "")])
    func emptySide(surface: String, reading: String) {
        #expect(runs(surface: surface, reading: reading) == nil)
    }
}
