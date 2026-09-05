import Foundation
@testable import Mimi
import Testing

// MARK: - Fixtures (shared by the ReadingAnnotator suites)

/// A token spanning `text` at the scalar offset `start`, carrying the given
/// surface reading (nil means unknown/unreadable).
func token(
    _ text: String, start: Int, reading: String? = nil
) -> DictionaryToken {
    DictionaryToken(
        text: text,
        start: start,
        end: start + text.unicodeScalars.count,
        reading: reading
    )
}

/// Contiguous tokens laid out left-to-right across the concatenated surfaces.
func tokens(
    _ surfaces: [String], readings: [String?]
) -> [DictionaryToken] {
    var start = 0
    return zip(surfaces, readings).map { surface, reading in
        defer { start += surface.unicodeScalars.count }
        return token(surface, start: start, reading: reading)
    }
}

/// Tokens laid out across space-separated surfaces — ASR output spaces out
/// words, and the contiguous `tokens` helper can't express those gaps.
func spacedTokens(
    _ surfaces: [String], readings: [String?]
) -> [DictionaryToken] {
    var start = 0
    return zip(surfaces, readings).map { surface, reading in
        defer { start += surface.unicodeScalars.count + 1 }
        return token(surface, start: start, reading: reading)
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
