import Foundation

/// A tapped word in annotated Japanese text: the payload `RubyTextView`
/// hands its host when cursor mode is `.dictionary`. `tokenIndex` is the
/// index into the rendered `ReadingAnnotator.segments` array — the forward
/// expansion unit — and `sentenceText` is the full sentence text at render
/// time, against which expansion validates adjacency.
struct LookupToken: Equatable, Sendable {
    /// The tapped segment's surface as rendered.
    let surface: String
    /// The segment's kana furigana when it carries one; kana-only surfaces
    /// are their own reading, and segments without an aligned reading are
    /// nil.
    let reading: String?
    /// The token's dictionary base form (言った → 言う) when the tokenizer
    /// supplied one.
    let lemma: String?
    /// Position of the tapped segment in the rendered segments array.
    let tokenIndex: Int
    /// The full sentence text the tap rendered from.
    let sentenceText: String
}
