import Foundation
@testable import Mimi
import Testing

// MARK: - Fixtures (shared by the ReadingAnnotator suites)

/// A kana reading with the JMdict flags the selection rule consumes.
func kana(
    _ text: String, priority: String? = nil, info: String? = nil
) -> DictionaryToken.KanaReading {
    DictionaryToken.KanaReading(text: text, priority: priority, info: info, matched: false)
}

/// A token spanning `text` at the scalar offset `start`, carrying the given
/// readings (an empty list means no dictionary entry).
func token(
    _ text: String, start: Int, readings: [DictionaryToken.KanaReading] = []
) -> DictionaryToken {
    DictionaryToken(
        text: text,
        start: start,
        end: start + text.unicodeScalars.count,
        dictionaryEntry: readings.isEmpty
            ? nil
            : DictionaryToken.Entry(kanjiReadings: [], kanaReadings: readings)
    )
}

/// Contiguous tokens laid out left-to-right across the concatenated surfaces.
func tokens(
    _ surfaces: [String], readings: [[DictionaryToken.KanaReading]]
) -> [DictionaryToken] {
    var start = 0
    return zip(surfaces, readings).map { surface, entryReadings in
        defer { start += surface.unicodeScalars.count }
        return token(surface, start: start, readings: entryReadings)
    }
}

/// An annotator that replays canned tokens, independent of the runtime.
func makeAnnotator(_ canned: [DictionaryToken]) -> ReadingAnnotator {
    ReadingAnnotator(tokenize: { _ in canned })
}

/// Compact [surface, romaji, furigana] rows for whole-segment assertions.
func describe(_ segments: [ReadingSegment]?) -> [[String?]] {
    segments?.map { [$0.surface, $0.romaji, $0.furigana] } ?? []
}
