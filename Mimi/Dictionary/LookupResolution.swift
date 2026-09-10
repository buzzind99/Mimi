import Foundation

/// A tap's resolution: found — the tapped word's own surface or lemma, or
/// the join it leads, matched an entry — or not-found, where the tapped
/// word itself has no entry and only the deep kanji-split fallbacks hit.
/// A not-found resolution never promotes a split to the display result;
/// its hits travel as `related`, which the UI demotes to suggestions.
enum LookupResolution: Equatable, Sendable {
    case found(LookupOutcome)
    case notFound(related: [LookupResult])
}
