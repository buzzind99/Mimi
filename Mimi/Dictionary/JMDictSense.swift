import Foundation

/// One sense of a JMDict entry.
struct JMDictSense: Equatable, Sendable {
    /// Comma-joined part-of-speech tags as stored (`"n,vs,vi"`), or nil.
    let pos: String?
    let glosses: [String]
    /// Comma-space-joined misc tags as stored (`"col, uk"`), or nil.
    let misc: String?
    /// Kanji-writing restriction: nil = applies to every writing; non-nil =
    /// the exact writings it applies to (an empty array matches none —
    /// defensive, upstream never emits an empty list at sense level).
    let restrictedKanji: [String]?
    /// Same restriction semantics over kana readings.
    let restrictedKana: [String]?
}
