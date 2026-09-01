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
        let annotator = makeAnnotator(tokens(
            ["桜"], readings: [[kana("さくら", priority: "ichi1")]]
        ))

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

// MARK: - Reading selection

@Suite("ReadingAnnotator reading selection")
struct ReadingAnnotatorSelectionTests {

    @Test("prefers the reading equal to a kana-only surface (こっち, not こちら)")
    func surfaceExactForKanaOnly() throws {
        let annotator = makeAnnotator([
            token("こっち", start: 0, readings: [
                kana("こちら", priority: "ichi1"), kana("こっち", priority: "ichi1")
            ])
        ])

        let segments = try #require(annotator.segments(for: "こっち"))

        #expect(describe(segments) == [["こっち", "kocchi", nil]])
    }

    @Test("prefers the reading agreeing with the kana in a mixed surface (いい天気)")
    func kanaAgreementForMixedSurface() throws {
        let annotator = makeAnnotator([
            token("いい天気", start: 0, readings: [kana("よいてんき"), kana("いいてんき")])
        ])

        let segments = try #require(annotator.segments(for: "いい天気"))

        #expect(describe(segments) == [["いい天気", "iitenki", "いいてんき"]])
    }

    @Test("prefers the surface-exact katakana reading (ヴァイオリン, not バイオリン)")
    func surfaceExactKatakana() throws {
        let annotator = makeAnnotator([
            token("ヴァイオリン", start: 0, readings: [
                kana("バイオリン", priority: "gai1"), kana("ヴァイオリン", priority: "gai1")
            ])
        ])

        let segments = try #require(annotator.segments(for: "ヴァイオリン"))

        #expect(describe(segments) == [["ヴァイオリン", "vaiorin", nil]])
    }

    @Test("deprioritizes search-only kana forms (私 → わたし)")
    func searchOnlyDeprioritized() throws {
        let annotator = makeAnnotator([
            token("私", start: 0, readings: [
                kana("わたし", priority: "ichi1"),
                kana("ワタシ", info: "search-only kana form")
            ])
        ])

        let segments = try #require(annotator.segments(for: "私"))

        #expect(describe(segments) == [["私", "watashi", "わたし"]])
    }

    @Test("falls back to the first reading when all are search-only")
    func allSearchOnlyFallsBackToFirst() throws {
        let annotator = makeAnnotator([
            token("私", start: 0, readings: [
                kana("ワタシ", info: "search-only kana form"),
                kana("わたし", info: "search-only kana form")
            ])
        ])

        let segments = try #require(annotator.segments(for: "私"))

        #expect(describe(segments) == [["私", "watashi", "ワタシ"]])
    }

    @Test("ranks nfXX news-priority readings above unflagged ones")
    func nfPriorityBeatsUnflagged() throws {
        let annotator = makeAnnotator([
            token("天気", start: 0, readings: [
                kana("あ"),
                kana("い", priority: "unheard-of-tag"),
                kana("う", priority: "nf01")
            ])
        ])

        let segments = try #require(annotator.segments(for: "天気"))

        #expect(describe(segments) == [["天気", "u", "う"]])
    }

    @Test("keeps the dictionary's first reading on a priority tie (十回 → じっかい)")
    func priorityTieKeepsDictionaryOrder() throws {
        let annotator = makeAnnotator([
            token("十回", start: 0, readings: [kana("じっかい"), kana("じゅっかい")])
        ])

        let segments = try #require(annotator.segments(for: "十回"))

        #expect(describe(segments) == [["十回", "jikkai", "じっかい"]])
    }

    @Test("ranks ichi1 above spec1 (七 → しち)")
    func priorityRanking() throws {
        let annotator = makeAnnotator([
            token("七", start: 0, readings: [
                kana("なな", priority: "spec1"), kana("しち", priority: "ichi1")
            ])
        ])

        let segments = try #require(annotator.segments(for: "七"))

        #expect(describe(segments) == [["七", "shichi", "しち"]])
    }

    @Test("omits furigana for kana-only surfaces even when a reading exists")
    func furiganaOnlyForKanjiSurfaces() throws {
        let annotator = makeAnnotator([
            token("です", start: 0, readings: [kana("です", priority: "spec1")])
        ])

        let segments = try #require(annotator.segments(for: "です"))

        #expect(describe(segments) == [["です", "desu", nil]])
    }

    @Test("reads particles by function, not by dictionary reading",
          arguments: [("は", "wa"), ("へ", "e"), ("を", "o")])
    func particleOverride(particle: String, expected: String) throws {
        let annotator = makeAnnotator([
            token(particle, start: 0, readings: [kana(particle, priority: "spec1")])
        ])

        let segments = try #require(annotator.segments(for: particle))

        #expect(describe(segments) == [[particle, expected, nil]])
    }

    @Test("does not override the katakana lookalike (ハ → ha)")
    func katakanaNotOverridden() throws {
        let annotator = makeAnnotator([
            token("ハ", start: 0, readings: [kana("ハ", priority: "spec1")])
        ])

        let segments = try #require(annotator.segments(for: "ハ"))

        #expect(describe(segments) == [["ハ", "ha", nil]])
    }

    @Test("uses the established loanword spelling for 抹茶")
    func matchaLexicalOverride() throws {
        let annotator = makeAnnotator([
            token("抹茶", start: 0, readings: [kana("まっちゃ")])
        ])

        let segments = try #require(annotator.segments(for: "抹茶"))

        #expect(describe(segments) == [["抹茶", "matcha", "まっちゃ"]])
    }

    @Test("self-transcribes entry-less tokens unannotated",
          arguments: [("𠮷", "𠮷"), ("。", "。"), ("H", "H"), ("っ", "っ")])
    func entryLessSelfTranscribed(surface: String, romaji: String) throws {
        let annotator = makeAnnotator([token(surface, start: 0, readings: [])])

        let segments = try #require(annotator.segments(for: surface))

        #expect(describe(segments) == [[surface, romaji, nil]])
    }

    @Test("falls back to the surface romaji when the reading can't convert")
    func unmappableReadingFallsBackToSurface() throws {
        let annotator = makeAnnotator([
            token("漢", start: 0, readings: [kana("漢字")])
        ])

        let segments = try #require(annotator.segments(for: "漢"))

        #expect(describe(segments) == [["漢", "漢", "漢字"]])
    }
}
