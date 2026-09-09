import Foundation

/// One rendered-annotation segment snapshot for dictionary lookup: the
/// fields forward expansion reads off the `ReadingAnnotator.segments`
/// element a tap resolved against. A value snapshot keeps the expansion a
/// pure function of its inputs.
struct LookupSegment: Equatable, Sendable {
    let surface: String
    /// The segment's kana reading as displayed (furigana; a kana-only
    /// surface is its own reading) — entries whose entry reading matches
    /// rank first in the lookup result. nil when the segment carries no
    /// readable kana (numerals, reading-less kanji, plain runs).
    let reading: String?
    /// The token's dictionary base form (言った → 言う) when the tokenizer
    /// supplied one, else nil (numerals, plain runs, entry-less tokens).
    let lemma: String?

    init(surface: String, lemma: String? = nil, reading: String? = nil) {
        self.surface = surface
        self.reading = reading
        self.lemma = lemma
    }
}

/// Forward expansion for a dictionary tap: from the tapped segment it walks
/// the same segments array the tap rendered from, joining up to `maxTokens`
/// consecutive word segments into lookup-candidate fallbacks (お+土産 →
/// お土産 offered when the tapped piece alone misses).
///
/// The tapped segment's own candidates lead — surface, then lemma — so the
/// word the user tapped always takes the display result and a longer join
/// that also hits lands in the outcome's "also:" list. Conjugated forms
/// fall back to their lemma (base form) when the surface itself isn't a
/// headword. The joins follow in longest-first order for taps whose own
/// text isn't a dictionary headword.
///
/// Join rules mirror the annotator's own span-merge guards: whitespace-only
/// segments between words are skipped, while numeral runs, the
/// particle-override particles (は/へ/を), and punctuation-only segments
/// stop expansion — never bridged across.
///
/// Adjacency is validated against the sentence's full text at render time:
/// the original text between two joined surfaces must be empty or
/// whitespace-only. The segments array can lag the text it rendered from
/// (live partials grow between render and tap), so a joined surface that no
/// longer sits — whitespace gaps aside — where the sentence text has it
/// stops the walk instead of producing a candidate that bridges a gap.
enum JMDictExpansion {
    /// Segments one candidate may join, the tapped segment included.
    static let maxTokens = 3
    /// Candidates queried per tap, one exact index hit each.
    static let maxCandidates = 3

    /// Particles the annotator reads by function, not by dictionary reading
    /// (`ReadingAnnotator.particleRomaji`): expansion never bridges them.
    private static let particleOverrides: Set<String> = ["は", "へ", "を"]

    /// Candidates for a tap on `index`: the tapped segment's surface first,
    /// then its lemma (conjugated forms fall back to their base form), then
    /// the validated forward joins longest-first. Truncated to
    /// `maxCandidates`, tapped candidates first, so the word the user tapped
    /// always leads the display result and a tap costs at most three indexed
    /// queries.
    static func candidates(
        segments: [LookupSegment], tappedAt index: Int, sentenceText: String
    ) -> [LookupCandidate] {
        guard segments.indices.contains(index) else { return [] }

        var candidates: [LookupCandidate] = []
        let tapped = segments[index]
        if !tapped.surface.isEmpty {
            candidates.append(LookupCandidate(text: tapped.surface, reading: tapped.reading))
        }
        if let lemma = tapped.lemma, !lemma.isEmpty, lemma != tapped.surface {
            candidates.append(LookupCandidate(text: lemma, reading: tapped.reading))
        }
        let members = joinedSegments(
            segments: segments, tappedAt: index, sentenceText: sentenceText
        )
        for count in stride(from: min(maxTokens, members.count), to: 1, by: -1) {
            let text = members[..<count].map(\.surface).joined()
            if !text.isEmpty {
                candidates.append(LookupCandidate(text: text, reading: joinedReading(members[..<count])))
            }
        }
        return Array(candidates.prefix(maxCandidates))
    }

    /// The concatenated readings of a join, nil unless every member carries
    /// one — a partially known reading can't match the joined surface's
    /// entry reading, so it is dropped rather than trusted.
    private static func joinedReading(_ members: ArraySlice<LookupSegment>) -> String? {
        var reading = ""
        for member in members {
            guard let part = member.reading, !part.isEmpty else { return nil }
            reading += part
        }
        return reading.isEmpty ? nil : reading
    }

    /// The tapped segment plus the forward neighbors that may join it, in
    /// order, capped at `maxTokens`. The walk stops at the first segment
    /// that fails a join rule.
    private static func joinedSegments(
        segments: [LookupSegment], tappedAt index: Int, sentenceText: String
    ) -> [LookupSegment] {
        var members = [segments[index]]
        // Character-array coordinates: String indices are not interchangeable
        // across strings, and sentence lengths here are small.
        let sentence = Array(sentenceText)
        // The segments' surfaces concatenate back to the (trimmed) text they
        // were rendered from; anchoring at its first occurrence places the
        // cursor past the tapped surface even when the sentence carries
        // surrounding whitespace. A sentence text that has drifted away from
        // the segments degrades the anchor to the start, and the adjacency
        // scan below then fails closed — joins stop, single candidates stay.
        let body = segments.map(\.surface).joined()
        let base: Int
        if let range = sentenceText.firstRange(of: body) {
            base = sentenceText.distance(from: sentenceText.startIndex, to: range.lowerBound)
        } else {
            base = 0
        }
        var cursor = base + segments[...index].reduce(0) { $0 + $1.surface.count }

        for position in segments.indices.dropFirst(index + 1) {
            let surface = segments[position].surface
            if surface.allSatisfy({ $0.isWhitespace }) {
                continue
            }
            if ReadingAnnotator.isNumeralRun(surface)
                || particleOverrides.contains(surface)
                || !surface.contains(where: { $0.isLetter || $0.isNumber })
            {
                break
            }
            guard let start = scanSurface(Array(surface), from: cursor, in: sentence) else {
                break
            }
            members.append(segments[position])
            cursor = start + surface.count
            if members.count == maxTokens {
                break
            }
        }
        return members
    }

    /// The first offset at or after `cursor` where `surface` sits in
    /// `sentence`, scanning across whitespace only. A non-whitespace
    /// character that doesn't start the surface — punctuation, or any other
    /// gap the segments don't show — ends the scan with no match.
    private static func scanSurface(
        _ surface: [Character], from cursor: Int, in sentence: [Character]
    ) -> Int? {
        var position = cursor
        while position + surface.count <= sentence.count {
            if sentence[position ..< position + surface.count].elementsEqual(surface) {
                return position
            }
            guard sentence[position].isWhitespace else { return nil }
            position += 1
        }
        return nil
    }
}

// MARK: - Engine entry point

extension JMDictLookup {
    /// Looks up a tap with forward expansion: builds the candidates from the
    /// rendered segments (`JMDictExpansion.candidates`) and resolves them in
    /// order. The first candidate with a hit is the display result — the
    /// tapped segment's own candidates lead, so the tapped word displays and
    /// longer joins that also hit are retained as "also:" results. Every
    /// candidate missing → nil; an infrastructure error on any query aborts
    /// the tap as a throw — never a miss.
    func lookup(
        segments: [LookupSegment], tappedAt index: Int, sentenceText: String
    ) throws -> LookupOutcome? {
        try lookup(JMDictExpansion.candidates(
            segments: segments, tappedAt: index, sentenceText: sentenceText
        ))
    }
}
