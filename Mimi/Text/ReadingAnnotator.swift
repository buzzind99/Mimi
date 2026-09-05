import Foundation

/// One rendered run of text plus its optional romaji/kana annotations. The
/// `surface` strings concatenate back to the original text (uncovered spans
/// and runtime failures become plain runs). A run whose romaji equals its
/// surface (Latin, digits, punctuation, kanji without a dictionary reading)
/// is self-transcribed; renderers skip annotating those. `furigana` is only
/// populated for kanji-bearing runs.
final class ReadingSegment {
    var surface: String
    var romaji: String?
    var furigana: String?

    init(surface: String, romaji: String?, furigana: String? = nil) {
        self.surface = surface
        self.romaji = romaji
        self.furigana = furigana
    }
}

/// Produces romaji (wapuro long vowels, Hepburn consonants) and kana
/// furigana for Japanese text from the dictionary tokenizer's per-surface
/// kana readings (`DictionaryEngine`), plus a numeral→counter fusion pass in
/// kana space so Arabic-digit counters read correctly (`600回` →
/// "roppyakkai"). The dictionary may still be preparing on first launch;
/// every failure degrades to plain text.
/// Sendable by immutability contract: `cache` and `tokenize` are set in init
/// and never mutated afterwards; `NSCache` is internally thread-safe.
final class ReadingAnnotator: @unchecked Sendable {
    /// The process-wide annotator backing the static entry point.
    static let shared = ReadingAnnotator()

    private let cache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 500
        return cache
    }()

    /// The token source; injectable so tests drive the annotator without the
    /// dictionary runtime.
    private let tokenize: (String) -> [DictionaryToken]?

    init(tokenize: @escaping (String) -> [DictionaryToken]? = {
        DictionaryEngine.shared.tokenize($0)
    }) {
        self.tokenize = tokenize
    }

    /// Returns per-run segments for `text` (surface + romaji + furigana), or
    /// `nil` for empty input. Cached.
    static func segments(for text: String) -> [ReadingSegment]? {
        shared.segments(for: text)
    }

    func segments(for text: String) -> [ReadingSegment]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let cached = cache.object(forKey: trimmed as NSString) as? [ReadingSegment] {
            return cached
        }

        let result = transcribe(trimmed)
        cache.setObject(result as NSArray, forKey: trimmed as NSString)
        return result
    }

    // MARK: - Transcription

    private func transcribe(_ text: String) -> [ReadingSegment] {
        guard let tokens = tokenize(text) else { return [] }
        let scalars = Array(text.unicodeScalars)
        var segments: [ReadingSegment] = []
        var cursor = 0
        // A numeral run held back for counter fusion (一回 → "ikkai").
        var pending: PendingNumber?

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token.start > cursor {
                let low = max(0, min(cursor, scalars.count))
                let high = max(low, min(token.start, scalars.count))
                let span = String(String.UnicodeScalarView(scalars[low ..< high]))
                // Whitespace between a held-back number and what follows
                // rides along in the pending run ("2 人" still fuses —
                // ASR output spaces out words); any other uncovered span
                // (三、四本) flushes it, then emits the span as a plain run.
                if pending != nil, span.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
                    pending?.gap = span
                    cursor = token.start
                } else {
                    flush(&pending, into: &segments)
                    appendSpan(from: cursor, to: token.start, of: scalars, into: &segments)
                }
            }
            let surface = Self.scalarSlice(token, of: scalars)
            cursor = token.end

            if Self.isNumeralRun(surface) {
                Self.accumulate(token, surface: surface, into: &pending)
                i += 1
            } else if !fuse(&pending, with: token, surface: surface, into: &segments) {
                if let merged = sokuonMergedSpan(
                    at: i, surface: surface, tokens: tokens, scalars: scalars
                ) {
                    appendToken(
                        DictionaryToken(
                            text: merged.surface,
                            start: token.start,
                            end: tokens[merged.end].end,
                            reading: merged.kana
                        ),
                        surface: merged.surface,
                        into: &segments
                    )
                    cursor = tokens[merged.end].end
                    i = merged.end + 1
                } else {
                    appendToken(token, surface: surface, into: &segments)
                    i += 1
                }
            } else {
                i += 1
            }
        }
        flush(&pending, into: &segments)
        appendSpan(from: cursor, to: scalars.count, of: scalars, into: &segments)
        return segments
    }

    /// Emits a non-numeral token: the dictionary's surface reading converted
    /// to romaji (with particle and lexical overrides), furigana only for
    /// kanji-bearing surfaces. Kana-only tokens without a dictionary reading
    /// (unknown katakana, stray kana) read themselves by construction; other
    /// entry-less tokens (names, rare ideographs, punctuation, bare Latin)
    /// stay self-transcribed and unannotated.
    private func appendToken(
        _ token: DictionaryToken, surface: String, into segments: inout [ReadingSegment]
    ) {
        guard var reading = token.reading ?? Self.selfReading(surface) else {
            segments.append(ReadingSegment(surface: surface, romaji: surface, furigana: nil))
            return
        }
        reading = Self.lexicalKana[reading] ?? reading
        var romaji = KanaRomaji.romaji(fromKana: reading) ?? surface
        if let lexical = Self.lexicalRomaji[reading] {
            romaji = lexical
        } else if let particle = Self.particleRomaji[surface] {
            romaji = particle
        }
        segments.append(ReadingSegment(
            surface: surface,
            romaji: romaji,
            furigana: Self.furigana(surface: surface, reading: reading)
        ))
    }

    /// Joins a sokuon-bearing token with what follows. IPADIC splits
    /// conjugated forms at the stem boundary (言って → 言っ/て), stranding the
    /// gemination target in the next token's reading; when the pair is
    /// adjacent — or separated only by whitespace, which ASR output inserts
    /// between words (ちゃっ た) — and the next reading begins with a
    /// geminable mora, the two merge into one segment (surface 言って,
    /// reading イッテ) so `KanaRomaji` derives "itte". The merge chains: ASR
    /// spacing can strand several sokuons in a row (なっ ちゃっ てる), so
    /// tokens keep absorbing while the accumulated reading still ends in a
    /// sokuon (なっちゃってる). The intervening `gap` ("" when adjacent) must
    /// be whitespace-only — any other uncovered span blocks the merge — and
    /// folds into the merged surface so it isn't dropped. Overridden
    /// particles (って + は) and numeral runs keep their own conversions; a
    /// genuinely stranded sokuon falls back to the spoken "tsu".
    /// A completed sokuon chain merge: the folded surface, the accumulated
    /// kana, and the index of the last absorbed token.
    private struct SokuonMerge {
        var surface: String
        var kana: String
        var end: Int
    }

    private func sokuonMergedSpan(
        at index: Int, surface: String,
        tokens: [DictionaryToken], scalars: [Unicode.Scalar]
    ) -> SokuonMerge? {
        guard var kana = tokens[index].reading ?? Self.selfReading(surface),
              kana.unicodeScalars.last.map(Self.isSokuon) == true
        else { return nil }

        var mergedSurface = surface
        var end = index
        var previousEnd = tokens[index].end
        while kana.unicodeScalars.last.map(Self.isSokuon) == true, end + 1 < tokens.count {
            let next = tokens[end + 1]
            let nextSurface = Self.scalarSlice(next, of: scalars)
            var gap = ""
            if next.start > previousEnd {
                let low = min(previousEnd, scalars.count)
                let high = min(next.start, scalars.count)
                gap = String(String.UnicodeScalarView(scalars[low ..< high]))
            }
            guard next.start >= previousEnd,
                  gap.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }),
                  let nextReading = next.reading ?? Self.selfReading(nextSurface),
                  !Self.isNumeralRun(nextSurface),
                  Self.particleRomaji[nextSurface] == nil,
                  KanaRomaji.geminates(fromKana: nextReading)
            else { break }
            mergedSurface += gap + nextSurface
            kana += nextReading
            end += 1
            previousEnd = next.end
        }
        guard end > index else { return nil }
        return SokuonMerge(surface: mergedSurface, kana: kana, end: end)
    }

    private static func isSokuon(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x3063 || scalar.value == 0x30C3 // っ, ッ
    }

    /// A kana-only surface's reading is the surface itself: kana carries its
    /// pronunciation by construction, so unknown katakana and stray kana
    /// still romaji-convert instead of rendering unannotated.
    private static func selfReading(_ surface: String) -> String? {
        guard !surface.isEmpty else { return nil }
        return surface.unicodeScalars.allSatisfy(KanaClassification.isKana) ? surface : nil
    }

    /// Furigana for kanji-bearing surfaces: the reading run aligned with the
    /// surface (`ReadingAlignment`) — under IPADIC's per-surface readings
    /// this succeeds for essentially every conjugated token (見た → み walks
    /// 見). Rare quirky readings that don't walk their surface fall back to
    /// the whole-surface reading — shown, never hidden. Kana-only surfaces
    /// need none.
    private static func furigana(surface: String, reading: String) -> String? {
        guard KanaClassification.containsKanji(surface) else { return nil }
        return ReadingAlignment.runs(surface: surface, reading: reading)?
            .map(\.kana).joined() ?? reading
    }

    /// Uncovered spans (the tokenizer should cover everything, but a gap may
    /// appear on engine hiccups) stay plain runs so surfaces concatenate back.
    private func appendSpan(
        from start: Int, to end: Int, of scalars: [Unicode.Scalar],
        into segments: inout [ReadingSegment]
    ) {
        guard start < end else { return }
        let gap = String(String.UnicodeScalarView(scalars[start ..< end]))
        segments.append(ReadingSegment(surface: gap, romaji: gap, furigana: nil))
    }

    // MARK: - Overrides

    /// Topic/directional/object particles read by function, not by their
    /// dictionary reading (は → "wa", not "ha").
    private static let particleRomaji = ["は": "wa", "へ": "e", "を": "o"]

    /// Established spellings the kana conversion can't produce: the
    /// greetings' fused particle (は → "ha" mechanically, "wa" by
    /// convention; keyed by reading so the fused kanji forms 今日は and
    /// 今晩は inherit it) and 抹茶's maccha → matcha. The conjunctions
    /// では/それでは/または are single dictionary entries carrying their
    /// etymological は, which is still spoken as the particle "wa" —
    /// segmented で+は contexts reach the bare-particle override instead.
    private static let lexicalRomaji = [
        "こんにちは": "konnichiwa", "こんばんは": "konbanwa", "まっちゃ": "matcha",
        "それでは": "soredewa", "では": "dewa", "または": "matawa"
    ]

    /// Dictionary readings repaired to the spoken form, keyed by the entry's
    /// kana: 入口/入り口 carries the etymological いりくち but is spoken with
    /// rendaku (いりぐち) — keyed by reading so both written forms inherit it.
    private static let lexicalKana = ["いりくち": "いりぐち"]

    // MARK: - Text helpers

    /// Slices the token's scalar span — `start`/`end` are Unicode-scalar
    /// indices into the original input, never `String.Index` values.
    private static func scalarSlice(
        _ token: DictionaryToken, of scalars: [Unicode.Scalar]
    ) -> String {
        let low = max(0, min(token.start, scalars.count))
        let high = max(low, min(token.end, scalars.count))
        return String(String.UnicodeScalarView(scalars[low ..< high]))
    }
}
