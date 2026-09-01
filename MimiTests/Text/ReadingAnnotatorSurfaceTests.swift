import Foundation
@testable import Mimi
import Testing

// MARK: - Surfaces

@Suite("ReadingAnnotator surfaces")
struct ReadingAnnotatorSurfaceTests {

    @Test("surfaces concatenate back to the input across mixed tokens")
    func concatenateBack() throws {
        let text = "600回、桜ですA B𠮷"
        let annotator = makeAnnotator(tokens(
            ["6", "0", "0", "回", "、", "桜", "です", "A", " ", "B", "𠮷"],
            readings: [
                [], [], [], [kana("かい", priority: "ichi1")], [],
                [kana("さくら", priority: "ichi1")], [kana("です", priority: "spec1")],
                [], [], [], []
            ]
        ))

        let segments = try #require(annotator.segments(for: text))

        #expect(segments.map(\.surface).joined() == text)
    }

    @Test("emits a plain run for spans the runtime doesn't cover")
    func gapBecomesPlainRun() throws {
        let text = "あXい"
        let annotator = makeAnnotator([
            token("あ", start: 0, readings: [kana("あ")]),
            token("い", start: 2, readings: [kana("い")])
        ])

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [["あ", "a", nil], ["X", "X", nil], ["い", "i", nil]])
    }
}
