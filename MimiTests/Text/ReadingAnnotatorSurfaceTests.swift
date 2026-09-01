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
            ["600", "回", "、", "桜", "です", "A", " ", "B", "𠮷"],
            readings: [nil, "かい", nil, "さくら", "です", nil, nil, nil, nil]
        ))

        let segments = try #require(annotator.segments(for: text))

        #expect(segments.map(\.surface).joined() == text)
    }

    @Test("emits a plain run for spans the runtime doesn't cover")
    func gapBecomesPlainRun() throws {
        let text = "あXい"
        let annotator = makeAnnotator([
            token("あ", start: 0, reading: "あ"),
            token("い", start: 2, reading: "い")
        ])

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [["あ", "a", nil], ["X", "X", nil], ["い", "i", nil]])
    }
}
