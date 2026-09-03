import Foundation
@testable import Mimi
import Testing

// MARK: - Guards and caching

@Suite("ReadingAnnotator input guards")
struct ReadingAnnotatorGuardTests {

    @Test("returns nil for empty and whitespace-only input", arguments: ["", "   ", "\n\t "])
    func nilForEmpty(text: String) {
        let annotator = makeAnnotator([])

        let segments = annotator.segments(for: text)

        #expect(segments == nil)
    }

    @Test("degrades to an empty segment list when the dictionary runtime is unavailable")
    func emptyWhenRuntimeUnavailable() {
        let annotator = ReadingAnnotator(tokenize: { _ in nil })

        let segments = annotator.segments(for: "こんにちは")

        #expect(segments?.isEmpty == true)
    }

    @Test("renders an all-plain run when the runtime returns no tokens")
    func emptyWhenNoTokens() {
        let annotator = makeAnnotator([])

        let segments = annotator.segments(for: "こんにちは")

        #expect(describe(segments) == [["こんにちは", "こんにちは", nil]])
    }

    @Test("caches segments: a repeated call returns the identical object")
    func cacheIdentity() throws {
        let annotator = makeAnnotator(tokens(["桜"], readings: ["さくら"]))

        let first = try #require(annotator.segments(for: "桜")?.first)
        let second = annotator.segments(for: "桜")?.first

        #expect(first === second)
    }

    @Test("the static entry point routes through the shared annotator")
    func staticEntryPoint() {
        let segments = ReadingAnnotator.segments(for: "こんにちは")

        #expect(segments != nil)
    }
}

// MARK: - Annotations

@Suite("ReadingAnnotator annotations")
struct ReadingAnnotatorAnnotationTests {

    @Test("omits furigana for kana-only surfaces even when a reading exists")
    func furiganaOnlyForKanjiSurfaces() throws {
        let annotator = makeAnnotator([token("です", start: 0, reading: "です")])

        let segments = try #require(annotator.segments(for: "です"))

        #expect(describe(segments) == [["です", "desu", nil]])
    }

    @Test("reads particles by function, not by dictionary reading",
          arguments: [("は", "wa"), ("へ", "e"), ("を", "o")])
    func particleOverride(particle: String, expected: String) throws {
        let annotator = makeAnnotator([token(particle, start: 0, reading: particle)])

        let segments = try #require(annotator.segments(for: particle))

        #expect(describe(segments) == [[particle, expected, nil]])
    }

    @Test("does not override the katakana lookalike (ハ → ha)")
    func katakanaNotOverridden() throws {
        let annotator = makeAnnotator([token("ハ", start: 0, reading: "ハ")])

        let segments = try #require(annotator.segments(for: "ハ"))

        #expect(describe(segments) == [["ハ", "ha", nil]])
    }

    @Test("uses the established loanword spelling for 抹茶")
    func matchaLexicalOverride() throws {
        let annotator = makeAnnotator([token("抹茶", start: 0, reading: "まっちゃ")])

        let segments = try #require(annotator.segments(for: "抹茶"))

        #expect(describe(segments) == [["抹茶", "matcha", "まっちゃ"]])
    }

    @Test("self-transcribes entry-less non-kana tokens unannotated",
          arguments: [("𠮷", "𠮷"), ("。", "。"), ("H", "H"), ("亜かな", "亜かな")])
    func readingLessSelfTranscribed(surface: String, romaji: String) throws {
        let annotator = makeAnnotator([token(surface, start: 0)])

        let segments = try #require(annotator.segments(for: surface))

        #expect(describe(segments) == [[surface, romaji, nil]])
    }

    @Test("kana-only tokens without a reading read themselves",
          arguments: [("かな", "kana"), ("カタカナ", "katakana"), ("っ", "tsu")])
    func kanaSelfReading(surface: String, romaji: String) throws {
        let annotator = makeAnnotator([token(surface, start: 0)])

        let segments = try #require(annotator.segments(for: surface))

        #expect(describe(segments) == [[surface, romaji, nil]])
    }

    @Test("furigana walks the surface for conjugated tokens (見た/みた)")
    func conjugatedFurigana() throws {
        let annotator = makeAnnotator([token("見た", start: 0, reading: "みた")])

        let segments = try #require(annotator.segments(for: "見た"))

        #expect(describe(segments) == [["見た", "mita", "みた"]])
    }

    @Test("folds katakana surfaces onto the hiragana reading for furigana")
    func katakanaFuriganaAlignment() throws {
        let annotator = makeAnnotator([token("ゲーム版", start: 0, reading: "げーむばん")])

        let segments = try #require(annotator.segments(for: "ゲーム版"))

        #expect(describe(segments) == [["ゲーム版", "geemuban", "げーむばん"]])
    }

    @Test("quirky readings that don't walk the surface fall back to whole-surface furigana")
    func quirkyReadingFallback() throws {
        let annotator = makeAnnotator([token("買った", start: 0, reading: "かう")])

        let segments = try #require(annotator.segments(for: "買った"))

        #expect(describe(segments) == [["買った", "kau", "かう"]])
    }

    @Test("falls back to the surface romaji when the reading can't convert")
    func unmappableReadingFallsBackToSurface() throws {
        let annotator = makeAnnotator([token("漢", start: 0, reading: "漢字")])

        let segments = try #require(annotator.segments(for: "漢"))

        #expect(describe(segments) == [["漢", "漢", "漢字"]])
    }

    // MARK: - Cross-token sokuon gemination

    @Test("merges a stem-final sokuon with the geminating next token",
          arguments: [
              ([("言っ", "いっ"), ("て", "て")],
               [["言って", "itte", "いって"]]),
              ([("なかっ", nil), ("た", nil)],
               [["なかった", "nakatta", nil]]),
              ([("行っ", "いっ"), ("ちゃ", "ちゃ")],
               [["行っちゃ", "iccha", "いっちゃ"]])
          ])
    func sokuonMergesWithNextToken(
        pair: [(String, String?)], expected: [[String?]]
    ) throws {
        let annotator = makeAnnotator(tokens(pair.map(\.0), readings: pair.map(\.1)))

        let segments = try #require(annotator.segments(for: pair.map(\.0).joined()))

        #expect(describe(segments) == expected)
    }

    @Test("a sokuon before a vowel-initial token stays stranded (spoken tsu)")
    func sokuonBeforeVowelDoesNotMerge() throws {
        let annotator = makeAnnotator(tokens(["言っ", "あ"], readings: ["いっ", "あ"]))

        let segments = try #require(annotator.segments(for: "言っあ"))

        #expect(describe(segments) == [["言っ", "itsu", "いっ"], ["あ", "a", nil]])
    }

    @Test("a sokuon before an overridden particle stays stranded")
    func sokuonBeforeParticleDoesNotMerge() throws {
        let annotator = makeAnnotator(tokens(["言っ", "は"], readings: ["いっ", "は"]))

        let segments = try #require(annotator.segments(for: "言っは"))

        #expect(describe(segments) == [["言っ", "itsu", "いっ"], ["は", "wa", nil]])
    }

    @Test("a sokuon token separated from the next by a gap stays stranded")
    func sokuonAcrossGapDoesNotMerge() throws {
        let annotator = makeAnnotator([
            token("言っ", start: 0, reading: "いっ"),
            token("て", start: 3, reading: "て")
        ])

        let segments = try #require(annotator.segments(for: "言っ て"))

        #expect(describe(segments) == [["言っ", "itsu", "いっ"], [" ", " ", nil], ["て", "te", nil]])
    }

    @Test("a trailing sokuon token has nothing to geminate with")
    func trailingSokuonStaysStranded() throws {
        let annotator = makeAnnotator(tokens(["そう", "言っ"], readings: ["そう", "いっ"]))

        let segments = try #require(annotator.segments(for: "そう言っ"))

        #expect(describe(segments) == [["そう", "sou", nil], ["言っ", "itsu", "いっ"]])
    }
}
