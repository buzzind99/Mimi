import Foundation

/// One lookup candidate: the exact string queried against `headwords.text`,
/// plus the headword kind the sense restriction filter is honored against.
struct LookupCandidate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Kanji-bearing writing (the DB's `keb` headword rows).
        case kanji
        /// Kana reading (the DB's `reb` headword rows).
        case kana
    }

    let text: String
    let kind: Kind
    /// The kana reading the tap's furigana (or kana surface) shows — after
    /// the surface-writing match, entries whose entry reading matches rank
    /// first within the result, since the displayed furigana reflects the
    /// reading in context. nil when the tap carries no readable kana; the
    /// ranking then ignores it.
    let reading: String?

    /// `kind` defaults to a script derivation: any ideographic scalar makes
    /// the candidate a kanji writing, anything else (hiragana, katakana,
    /// bare Latin) a reading.
    init(text: String, kind: Kind? = nil, reading: String? = nil) {
        self.text = text
        self.kind = kind ?? {
            let ideographic = text.unicodeScalars.contains { $0.properties.isIdeographic }
            return ideographic ? .kanji : .kana
        }()
        self.reading = reading
    }
}
