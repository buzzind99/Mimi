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

    @Test("self-transcribes tokens without a reading unannotated",
          arguments: [("𠮷", "𠮷"), ("。", "。"), ("H", "H"), ("っ", "っ")])
    func readingLessSelfTranscribed(surface: String, romaji: String) throws {
        let annotator = makeAnnotator([token(surface, start: 0)])

        let segments = try #require(annotator.segments(for: surface))

        #expect(describe(segments) == [[surface, romaji, nil]])
    }

    @Test("falls back to the surface romaji when the reading can't convert")
    func unmappableReadingFallsBackToSurface() throws {
        let annotator = makeAnnotator([token("漢", start: 0, reading: "漢字")])

        let segments = try #require(annotator.segments(for: "漢"))

        #expect(describe(segments) == [["漢", "漢", "漢字"]])
    }
}
