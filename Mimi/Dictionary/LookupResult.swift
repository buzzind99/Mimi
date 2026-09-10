import Foundation

/// One candidate's lookup outcome: the exact string that matched and every
/// entry sharing that headword, ranked surface-writing match first (the
/// entry written the way the tap is written leads), then furigana
/// reading-match, then common-first, then `ent_seq` — the stable order an
/// entry pager walks.
struct LookupResult: Equatable, Sendable {
    let matched: String
    let entries: [JMDictEntry]
}
