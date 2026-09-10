import Foundation

/// One JMDict entry. `jlpt` and the pitch fields come from the headword row
/// the candidate matched (per-writing values); `common` is entry-level.
struct JMDictEntry: Equatable, Sendable {
    let entSeq: Int
    let keb: String?
    let reb: String?
    let common: Bool
    let jlpt: Int?
    /// Verbatim Wadoku hatsuon text. Render-time gating (marked-up forms
    /// containing `< > [ ] ･ ~` are omitted) belongs to the UI layer.
    let hatsuon: String?
    let accPatts: String?
    /// Verbatim H/L pattern string (alphabet `H L h l ,` — not assumed pure).
    let zoPatts: String?
    let senses: [JMDictSense]
}
