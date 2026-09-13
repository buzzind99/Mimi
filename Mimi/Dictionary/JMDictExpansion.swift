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

/// The role a candidate played in the tap's expansion — the resolution
/// classifies the outcome by it: a join hit still leads the card (labeled
/// as a joined match, since the compound isn't the tapped word itself),
/// while a split hit never leads — split-only resolutions come back
/// not-found with their hits demoted to related suggestions.
enum ExpansionOrigin: Equatable, Sendable {
    /// The tapped segment's own surface.
    case tappedSurface
    /// The tapped segment's dictionary base form.
    case tappedLemma
    /// The tapped segment joined with forward neighbors.
    case join
    /// A kanji substring of the tapped surface, or a boundary-crossing
    /// substring of the joined text — the deep fallback.
    case split
}

/// One expansion candidate with the role it played for the tap.
struct ExpansionCandidate: Equatable, Sendable {
    let candidate: LookupCandidate
    let origin: ExpansionOrigin
}

/// Forward expansion for a dictionary tap: from the tapped segment it walks
/// the same segments array the tap rendered from, joining up to `maxTokens`
/// consecutive word segments into lookup-candidate fallbacks (お+土産 →
/// お土産 offered when the tapped piece alone misses), then splits the
/// tapped surface's contiguous kanji runs into substring candidates
/// (映画 → 映, 画) for compounds the tokenizer kept whole. The split then
/// runs once more over the joined expansion text as the deepest fallback,
/// emitting the substrings that straddle the tapped surface's trailing
/// edge (風呂+敷 → 呂敷) — a join that spans a real compound's edge can
/// still resolve its inner word.
///
/// The tapped segment's own candidates lead — surface, then lemma — so the
/// word the user tapped always takes the display result and a longer join
/// or split hit lands in the outcome's "also:" list. Conjugated forms
/// fall back to their lemma (base form) when the surface itself isn't a
/// headword. The joins follow in longest-first order for taps whose own
/// text isn't a dictionary headword, and the kanji-substring splits trail
/// them, longest substring first — the tapped surface's splits before the
/// joined text's — as the deep fallback.
///
/// Split candidates carry no reading: per-character division of the
/// segment's furigana isn't reliable (ateji, multi-character readings), so
/// the lookup ranking simply ignores readings for them.
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
    static let maxCandidates = 9
    /// Longest kanji substring a split emits, bounding the combinatorics of
    /// a long kanji run (uncapped, n kanji would emit n(n+1)/2 − 1
    /// substrings against the headword index).
    static let maxSplitLength = 3

    /// Particles the annotator reads by function, not by dictionary reading
    /// (`ReadingAnnotator.particleRomaji`): expansion never bridges them.
    private static let particleOverrides: Set<String> = ["は", "へ", "を"]

    /// The え-row kana a potential tail ends on, mapped onto its う-row
    /// counterpart (作れる: れ → る; 書ける: け → く).
    private static let potentialTailShift: [Character: Character] = [
        "え": "う", "け": "く", "げ": "ぐ", "せ": "す", "ぜ": "ず",
        "て": "つ", "で": "づ", "ね": "ぬ", "へ": "ふ", "べ": "ぶ",
        "ぺ": "ぷ", "め": "む", "れ": "る"
    ]

    /// The dictionary form a potential-form lemma unwraps to, or nil when
    /// the lemma doesn't shape like one. IPADIC lexicalizes potential forms
    /// as standalone verbs whose base is the potential itself (作れる), and
    /// JMDict headwords only carry the source verb (作る) — without this
    /// rewrite the lemma candidate misses and the tap falls through to the
    /// kanji splits. A られる tail unwraps plain (作られる → 作る, 食べられる →
    /// 食べる); otherwise the え-row tail kana shifts onto its う-row
    /// counterpart (作れる → 作る, 書ける → 書く). A wrong guess is inert — it
    /// merely misses the headword index, and any lemma that exists still
    /// hits on its own candidate first.
    static func dictionaryForm(ofPotential lemma: String) -> String? {
        let characters = Array(lemma)
        if characters.count > 3, characters.suffix(3).elementsEqual(["ら", "れ", "る"]) {
            return String(characters.dropLast(3)) + "る"
        }
        guard characters.count > 2, characters.last == "る",
              let shifted = potentialTailShift[characters[characters.count - 2]]
        else { return nil }
        return String(characters.dropLast(2)) + String(shifted)
    }

    /// Candidates for a tap on `index`, each tagged with the role it played:
    /// the tapped segment's surface first, then its lemma (conjugated forms
    /// fall back to their base form) followed by the dictionary form that
    /// lemma unwraps to when it shapes like a potential (IPADIC's
    /// standalone-potential lexicalization misses the headword index), then
    /// the validated forward joins longest-first, then the tapped surface's
    /// kanji-substring splits, then the joined expansion text's splits — the
    /// boundary-crossing substrings. Truncated to `maxCandidates`, tapped
    /// candidates first, so the word the user tapped always leads the
    /// display result and a tap costs at most `maxCandidates` indexed
    /// queries.
    static func candidates(
        segments: [LookupSegment], tappedAt index: Int, sentenceText: String
    ) -> [ExpansionCandidate] {
        guard segments.indices.contains(index) else { return [] }

        var candidates: [ExpansionCandidate] = []
        let tapped = segments[index]
        if !tapped.surface.isEmpty {
            candidates.append(ExpansionCandidate(
                candidate: LookupCandidate(text: tapped.surface, reading: tapped.reading),
                origin: .tappedSurface
            ))
        }
        if let lemma = tapped.lemma, !lemma.isEmpty {
            if lemma != tapped.surface {
                candidates.append(ExpansionCandidate(
                    candidate: LookupCandidate(text: lemma, reading: tapped.reading),
                    origin: .tappedLemma
                ))
            }
            // The unwrapped potential candidate trails the lemma itself (a
            // genuine dictionary form still resolves there first) and never
            // repeats the tapped surface's own query.
            if let dictionaryForm = Self.dictionaryForm(ofPotential: lemma),
               dictionaryForm != tapped.surface
            {
                candidates.append(ExpansionCandidate(
                    candidate: LookupCandidate(text: dictionaryForm, reading: tapped.reading),
                    origin: .tappedLemma
                ))
            }
        }
        let members = joinedSegments(
            segments: segments, tappedAt: index, sentenceText: sentenceText
        )
        for count in stride(from: min(maxTokens, members.count), to: 1, by: -1) {
            let text = members[..<count].map(\.surface).joined()
            if !text.isEmpty {
                candidates.append(ExpansionCandidate(
                    candidate: LookupCandidate(
                        text: text, reading: joinedReading(members[..<count])
                    ),
                    origin: .join
                ))
            }
        }
        // Split candidates trail the joins, deduplicated against everything
        // already emitted (the longest split of an all-kanji surface is the
        // surface itself; a short one can coincide with the lemma or a
        // join): the tapped surface's substrings first, then the joined
        // expansion text's boundary-crossing substrings (風呂+敷 → 呂敷) —
        // substrings wholly inside the tapped surface already came out of
        // the first pass, and ones wholly inside a neighbor stay one tap
        // away on that neighbor. The deep fallback never evicts the tapped
        // surface's own splits.
        var emitted = Set(candidates.map(\.candidate.text))
        let tappedSplits = splitCandidates(for: tapped.surface).filter {
            !emitted.contains($0.text)
        }
        candidates.append(contentsOf: tappedSplits.map {
            ExpansionCandidate(candidate: $0, origin: .split)
        })
        emitted.formUnion(tappedSplits.map(\.text))
        let crossingSplits = splitCandidates(
            for: members.map(\.surface).joined(),
            crossing: tapped.surface.unicodeScalars.count
        ).filter { !emitted.contains($0.text) }
        candidates.append(contentsOf: crossingSplits.map {
            ExpansionCandidate(candidate: $0, origin: .split)
        })
        return Array(candidates.prefix(maxCandidates))
    }

    /// A text's kanji-substring split candidates, longest substring first:
    /// the substrings (up to `maxSplitLength` characters) of each
    /// contiguous kanji run, lengths descending, left-to-right within a
    /// length (映画 → 映, 画 once the text itself is deduplicated away).
    /// With `crossing`, only the substrings straddling that scalar offset
    /// are emitted — substrings wholly on either side are dropped. Each
    /// candidate carries no reading — the lookup ranking ignores a nil
    /// reading.
    private static func splitCandidates(
        for text: String, crossing boundary: Int? = nil
    ) -> [LookupCandidate] {
        var candidates: [LookupCandidate] = []
        for length in stride(from: maxSplitLength, through: 1, by: -1) {
            for (offset, run) in kanjiRuns(in: text) where run.count >= length {
                for start in 0 ... run.count - length {
                    let base = offset + start
                    if let boundary, base + length <= boundary || base >= boundary {
                        continue
                    }
                    candidates.append(LookupCandidate(
                        text: String(String.UnicodeScalarView(run[start ..< start + length]))
                    ))
                }
            }
        }
        return candidates
    }

    /// The contiguous kanji runs of a text with each run's scalar start
    /// offset, in order (食べ物 → 食@0, 物@2; kana, numerals, and
    /// punctuation break a run).
    private static func kanjiRuns(
        in text: String
    ) -> [(offset: Int, scalars: [Unicode.Scalar])] {
        var runs: [(offset: Int, scalars: [Unicode.Scalar])] = []
        var current: [Unicode.Scalar] = []
        var scanned = 0
        for scalar in text.unicodeScalars {
            if KanaClassification.isKanji(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                runs.append((scanned - current.count, current))
                current = []
            }
            scanned += 1
        }
        if !current.isEmpty {
            runs.append((scanned - current.count, current))
        }
        return runs
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
    /// Looks up a tap with forward expansion: builds the expansion
    /// candidates from the rendered segments (`JMDictExpansion.candidates`)
    /// and resolves them in order. The tapped word's own surface or lemma
    /// hit leads the found outcome; a join hit also leads, its outcome
    /// carrying the join origin so the UI can label the compound match; a
    /// tap whose only hits are kanji splits resolves not-found with the
    /// split hits demoted to the related list — never displayed as the
    /// tapped word. An infrastructure error on any query aborts the tap as
    /// a throw — never a miss.
    func lookup(
        segments: [LookupSegment], tappedAt: Int, sentenceText: String
    ) throws -> LookupResolution {
        try lookup(JMDictExpansion.candidates(
            segments: segments, tappedAt: tappedAt, sentenceText: sentenceText
        ))
    }
}
