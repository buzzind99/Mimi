@testable import Mimi
import SwiftUI
import Testing

/// Tests the dictionary-mode view logic of `RubyTextView`: the pure
/// segment→unit mapping (words tappable, whitespace/punctuation inert),
/// the body plan (flow units, or the plain fallback that keeps the row
/// filled when the annotator yields nothing), the activation rule that
/// keeps the HUD on the legacy path, equality and fingerprint
/// mode-sensitivity, and the tap payload construction.
@Suite("RubyTextView dictionary mode")
@MainActor
struct RubyTextViewTests {

    // MARK: - Helpers

    private func segment(
        _ surface: String, romaji: String? = nil,
        furigana: String? = nil, lemma: String? = nil
    ) -> ReadingSegment {
        ReadingSegment(
            surface: surface, romaji: romaji ?? surface,
            furigana: furigana, lemma: lemma
        )
    }

    private func view(
        cursorMode: CursorMode = .none,
        onCopy: ((String) -> Void)? = nil,
        onLookup: ((LookupToken) -> Void)? = nil,
        lookupPopover: ((Int) -> RubyTextView.LookupPopover?)? = nil
    ) -> RubyTextView {
        RubyTextView(
            text: "テスト",
            surfaceFont: .system(size: 12),
            annotationFont: .system(size: 10, design: .monospaced),
            annotationColor: .primary,
            cursorMode: cursorMode,
            onCopy: onCopy,
            onLookup: onLookup,
            lookupPopover: lookupPopover
        )
    }

    // MARK: - Segment mapping

    @Test("under .none annotation every word unit renders plain, punctuation and whitespace stay inert")
    func noneAnnotationMapping() {
        let segments = [
            segment("今日", romaji: "kyou", lemma: "今日"),
            segment("、"),
            segment(" "),
            segment("ラーメン", romaji: "raamen")
        ]

        let units = RubyTextView.segmentedUnits(for: segments, annotation: .none)

        #expect(units == [
            .word(surface: "今日", note: nil),
            .inert(surface: "、"),
            .inert(surface: " "),
            .word(surface: "ラーメン", note: nil)
        ])
    }

    @Test("numeral runs stay tappable word units")
    func numeralRunsAreWords() {
        let units = RubyTextView.segmentedUnits(
            for: [segment("3", romaji: "san")], annotation: .none
        )

        #expect(units == [.word(surface: "3", note: nil)])
    }

    @Test("romaji notes follow the annotation mode and hide when equal to the surface")
    func romajiNotes() {
        let segments = [
            segment("私", romaji: "watashi", furigana: "わたし"),
            segment("は", romaji: "wa"),
            segment("ASR", romaji: "ASR")
        ]

        let romaji = RubyTextView.segmentedUnits(for: segments, annotation: .romaji)

        #expect(romaji == [
            .word(surface: "私", note: "watashi"),
            .word(surface: "は", note: "wa"),
            .word(surface: "ASR", note: nil)
        ])
    }

    @Test("furigana notes follow the annotation mode")
    func furiganaNotes() {
        let units = RubyTextView.segmentedUnits(
            for: [segment("私", romaji: "watashi", furigana: "わたし")],
            annotation: .furigana
        )

        #expect(units == [.word(surface: "私", note: "わたし")])
    }

    // MARK: - Activation rule

    @Test("dictionary mode is active only with .dictionary and a lookup handler")
    func activationMatrix() {
        #expect(view(cursorMode: .dictionary, onLookup: { _ in }).dictionaryLookupActive)
        #expect(!view(cursorMode: .dictionary, onLookup: nil).dictionaryLookupActive)
        #expect(!view(cursorMode: .copy, onLookup: { _ in }).dictionaryLookupActive)
        #expect(!view(cursorMode: .none, onLookup: { _ in }).dictionaryLookupActive)
    }

    // MARK: - Equality and fingerprint

    @Test("== is sensitive to cursor mode and blind to both closures")
    func equality() {
        let none = view()
        let dictionary = view(cursorMode: .dictionary)

        #expect(none != dictionary)

        let copyA = view(cursorMode: .copy, onCopy: { _ in })
        let copyB = view(cursorMode: .copy, onCopy: { _ in })
        #expect(copyA == copyB)

        let lookupA = view(cursorMode: .dictionary, onLookup: { _ in })
        let lookupB = view(cursorMode: .dictionary, onLookup: { _ in })
        #expect(lookupA == lookupB)

        #expect(view() == view(onLookup: { _ in }))
    }

    @Test("== is blind to the per-word popover host")
    func equalityIgnoresPopoverHost() {
        let hostedA = view(
            cursorMode: .dictionary, onLookup: { _ in },
            lookupPopover: { _ in nil }
        )
        let hostedB = view(
            cursorMode: .dictionary, onLookup: { _ in },
            lookupPopover: { _ in nil }
        )

        #expect(hostedA == hostedB)
        #expect(
            hostedA == view(cursorMode: .dictionary, onLookup: { _ in })
        )
    }

    @Test("fingerprint changes with cursor mode so the flow cache invalidates")
    func fingerprint() {
        #expect(view().fingerprint != view(cursorMode: .dictionary).fingerprint)
    }

    // MARK: - Body plan

    @Test("nil and empty segments plan the plain fallback so the row never blanks")
    func plainFallbackPlan() {
        #expect(
            RubyTextView.segmentedBodyPlan(segments: nil, annotation: .romaji) == .plain
        )
        #expect(
            RubyTextView.segmentedBodyPlan(segments: [], annotation: .furigana) == .plain
        )
    }

    @Test("non-empty segments plan the flow of their per-segment units")
    func flowPlan() {
        let segments = [
            segment("私", romaji: "watashi", furigana: "わたし"),
            segment("。")
        ]

        #expect(
            RubyTextView.segmentedBodyPlan(segments: segments, annotation: .furigana) == .flow([
                .word(surface: "私", note: "わたし"),
                .inert(surface: "。")
            ])
        )
    }

    // MARK: - Tap payload

    @Test("lookupToken carries surface, furigana reading, lemma, index, and sentence text")
    func payloadFields() {
        let segments = [
            segment("食べました", furigana: "たべました", lemma: "食べる"),
            segment("。")
        ]

        let token = RubyTextView.lookupToken(
            at: 0, text: "食べました。", segments: segments
        )

        #expect(token == LookupToken(
            surface: "食べました",
            reading: "たべました",
            lemma: "食べる",
            tokenIndex: 0,
            sentenceText: "食べました。"
        ))
    }

    @Test("lookupToken fails closed on nil segments and out-of-range indices")
    func payloadFailClosed() {
        let segments = [segment("今日", lemma: "今日")]

        #expect(RubyTextView.lookupToken(at: 0, text: "今日", segments: nil) == nil)
        #expect(RubyTextView.lookupToken(at: 1, text: "今日", segments: segments) == nil)
        #expect(RubyTextView.lookupToken(at: -1, text: "今日", segments: segments) == nil)
    }
}
