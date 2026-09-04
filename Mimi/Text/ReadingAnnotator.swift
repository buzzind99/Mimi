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
                // A held-back number never fuses across an uncovered span
                // (三、四本): flush it, then emit the span as a plain run.
                flush(&pending, into: &segments)
                appendSpan(from: cursor, to: token.start, of: scalars, into: &segments)
            }
            let surface = Self.scalarSlice(token, of: scalars)
            cursor = token.end

            if Self.isNumeralRun(surface) {
                Self.accumulate(token, surface: surface, into: &pending)
                i += 1
            } else if !fuse(&pending, with: token, surface: surface, into: &segments) {
                let nextSurface = i + 1 < tokens.count
                    ? Self.scalarSlice(tokens[i + 1], of: scalars) : nil
                if let merged = sokuonMergedSpan(
                    token, surface: surface, next: i + 1 < tokens.count ? tokens[i + 1] : nil,
                    nextSurface: nextSurface
                ) {
                    appendToken(
                        DictionaryToken(
                            text: merged.surface,
                            start: token.start,
                            end: tokens[i + 1].end,
                            reading: merged.kana
                        ),
                        surface: merged.surface,
                        into: &segments
                    )
                    cursor = tokens[i + 1].end
                    i += 2
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
        guard let reading = token.reading ?? Self.selfReading(surface) else {
            segments.append(ReadingSegment(surface: surface, romaji: surface, furigana: nil))
            return
        }
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

    /// Joins a sokuon-bearing token with the following one. IPADIC splits
    /// conjugated forms at the stem boundary (言って → 言っ/て), stranding the
    /// gemination target in the next token's reading; when the pair is
    /// contiguous and the next reading begins with a geminable mora, the two
    /// merge into one segment (surface 言って, reading イッテ) so `KanaRomaji`
    /// derives "itte". Overridden particles (って + は) and numeral runs keep
    /// their own conversions; a genuinely stranded sokuon falls back to the
    /// spoken "tsu".
    private func sokuonMergedSpan(
        _ token: DictionaryToken, surface: String, next: DictionaryToken?, nextSurface: String?
    ) -> (surface: String, kana: String)? {
        guard let next, let nextSurface, next.start == token.end else { return nil }
        guard let reading = token.reading ?? Self.selfReading(surface),
              reading.unicodeScalars.last.map(Self.isSokuon) == true
        else { return nil }
        guard let nextReading = next.reading ?? Self.selfReading(nextSurface),
              !Self.isNumeralRun(nextSurface),
              Self.particleRomaji[nextSurface] == nil,
              KanaRomaji.geminates(fromKana: nextReading)
        else { return nil }
        return (surface: surface + nextSurface, kana: reading + nextReading)
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

    /// Emits a kana reading (from the dictionary, the digit table, or a
    /// fusion) as a segment, romaji derived with `KanaRomaji`.
    private func append(
        surface: String, kana: String, romaji: String? = nil, into segments: inout [ReadingSegment]
    ) {
        let converted = romaji ?? KanaRomaji.romaji(fromKana: kana) ?? surface
        segments.append(ReadingSegment(
            surface: surface,
            romaji: converted,
            furigana: KanaClassification.containsKanji(surface) ? kana : nil
        ))
    }

    /// Emits a held-back numeral run as its own segment. Digit runs without
    /// a table reading (123, 2026) stay unannotated.
    private func appendNumber(
        _ pending: PendingNumber, into segments: inout [ReadingSegment]
    ) {
        var held = pending
        Self.resolveDigits(into: &held)
        guard !held.unresolved, !held.kana.isEmpty else {
            segments.append(ReadingSegment(
                surface: held.surface, romaji: held.surface, furigana: nil
            ))
            return
        }
        append(surface: held.surface, kana: held.kana, into: &segments)
    }

    private func flush(
        _ pending: inout PendingNumber?, into segments: inout [ReadingSegment]
    ) {
        guard let held = pending else { return }
        pending = nil
        appendNumber(held, into: &segments)
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

    // MARK: - Numeral → counter fusion

    /// A numeral run held back for counter fusion: the consumed surface plus
    /// its kana reading so far. Digits accumulate as a normalized run and
    /// resolve through the digit table when the run completes.
    private struct PendingNumber {
        var surface: String
        var digits = "" // fullwidth-normalized digit run awaiting lookup
        var kana = "" // accumulated kana of resolved parts
        var unresolved = false // a digit run with no table reading poisons the whole

        init(surface: String, digits: String = "", kana: String = "", unresolved: Bool = false) {
            self.surface = surface
            self.digits = digits
            self.kana = kana
            self.unresolved = unresolved
        }
    }

    /// Folds the held digit run into the kana (600 → ろっぴゃく).
    private static func resolveDigits(into pending: inout PendingNumber) {
        guard !pending.digits.isEmpty else { return }
        if let mapped = digitReadings[pending.digits] {
            pending.kana += mapped
        } else {
            pending.unresolved = true
        }
        pending.digits = ""
    }

    /// Extends a held-back numeral run: digit tokens accumulate their
    /// normalized glyphs, kanji numerals contribute their dictionary kana
    /// (三→さん, 万→まん). Any unreadable part marks the run unannotatable.
    private static func accumulate(
        _ token: DictionaryToken, surface: String, into pending: inout PendingNumber?
    ) {
        let ascii = surface.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? surface
        if ascii.range(of: "^[0-9]+$", options: .regularExpression) != nil {
            if pending != nil {
                pending?.surface += surface
                pending?.digits += ascii
            } else {
                pending = PendingNumber(surface: surface, digits: ascii)
            }
            return
        }
        let kana = token.reading
        if pending != nil {
            pending?.surface += surface
            resolveDigits(into: &pending!)
            if let kana {
                pending?.kana += kana
            } else {
                pending?.unresolved = true
            }
        } else {
            pending = PendingNumber(
                surface: surface, kana: kana ?? "", unresolved: kana == nil
            )
        }
    }

    /// Fuses a held-back numeral run with the following token, or flushes
    /// the run as its own segment. Returns true when `token` is fully
    /// handled (fused into the number, or given a special-case counter
    /// reading after the flush); false when the caller emits it normally.
    private func fuse(
        _ pending: inout PendingNumber?, with token: DictionaryToken, surface: String,
        into segments: inout [ReadingSegment]
    ) -> Bool {
        guard var held = pending else { return false }
        Self.resolveDigits(into: &held)
        let reading = token.reading

        // 年 after a number is the counter year (２年 → "ni nen"), never the
        // standalone "toshi" reading, and it never geminates.
        if surface == "年" {
            pending = nil
            appendNumber(held, into: &segments)
            append(surface: surface, kana: "ねん", into: &segments)
            return true
        }
        // 本 after さん/まん/せん voices to "bon" (三万本): the dictionary
        // matches the shared もと/ほん entry, whose first reading is もと.
        if surface == "本", !held.kana.isEmpty,
           ["さん", "まん", "せん"].contains(where: held.kana.hasSuffix)
        {
            pending = nil
            appendNumber(held, into: &segments)
            append(surface: surface, kana: "ほん", romaji: "bon", into: &segments)
            return true
        }
        // 人 is the irregular people counter: the model always splits
        // 一人/二人/四人 into numeral + 人 (にん), and the fused readings
        // that split implies (いちにん/ににん/よんにん) are wrong — the words
        // read ひとり/ふたり/よにん.
        if surface == "人", !held.unresolved,
           let people = Self.peopleCounterReadings[held.kana]
        {
            pending = nil
            append(surface: held.surface + surface, kana: people, into: &segments)
            return true
        }
        // Generic fusion: the number keeps its geminating stem and the
        // counter takes a sokuon (ろく+かい → ろっかい), except where the
        // plain reading is lexical (六 + 歳/等/千) or the counter's onset
        // can't take a sokuon (ば行 keeps the plain reading, 一番 → いちばん).
        if !held.unresolved, !held.kana.isEmpty, let reading,
           !Self.rokuException(numberKana: held.kana, counterKana: reading),
           !Self.voicedOnsetException(reading),
           let stem = Self.geminationStem(of: held.kana), Self.isGeminable(reading)
        {
            pending = nil
            append(
                surface: held.surface + surface,
                kana: stem + "っ" + Self.postSokuonVoicing(reading),
                into: &segments
            )
            return true
        }
        pending = nil
        appendNumber(held, into: &segments)
        return false
    }

    /// Whether a counter reading can take a sokuon: its first mora must
    /// start with a geminable consonant (k/s/t rows; the は/ば rows realize
    /// as the p-series, the ち row as "cch" — `KanaRomaji` derives both).
    private static let geminableOnsets =
        "かきくけこさしすせそたちつてとはひふへほばびぶべぼぱぴぷぺぽ"

    private static func isGeminable(_ kana: String) -> Bool {
        guard let first = kana.unicodeScalars.first else { return false }
        return geminableOnsets.unicodeScalars.contains(first)
    }

    /// The stem a geminating numeral keeps before the っ: いち→い, ろく→ろ,
    /// はち→は, …じゅう→…じゅ, …ゃく→…ゃ (ひゃく→ひゃ, ろっぴゃく→ろっぴゃ).
    /// しち (七) never geminates; nor do に/さん/ご/よん/なな/せん/まん.
    private static func geminationStem(of kana: String) -> String? {
        let geminates = ["いち", "ろく", "はち", "じゅう", "ゃく"]
        guard geminates.contains(where: kana.hasSuffix) else { return nil }
        return String(kana.dropLast())
    }

    /// Irregular people-counter readings keyed by the number's kana: the
    /// two-token split 一+人 can only imply いちにん, never ひとり. Numbers
    /// outside the table (三人, 十人, 二十人) read regularly and stay on the
    /// generic path.
    private static let peopleCounterReadings: [String: String] = [
        "いち": "ひとり", "に": "ふたり", "よん": "よにん"
    ]

    /// 六 keeps its plain reading before 歳/等/千 (ろくさい/ろくとう/ろくせん):
    /// the fusion must not produce ろっさい.
    private static func rokuException(numberKana: String, counterKana: String) -> Bool {
        numberKana == "ろく" && ["さい", "とう", "せん"].contains { counterKana.hasPrefix($0) }
    }

    /// A ば行 onset keeps the plain reading for every numeral: 一番/六番/十番/
    /// 八番/百番 all read without a sokuon (いちばん/ろくばん/じゅうばん/はちばん/
    /// ひゃくばん). だ/が行 onsets can't geminate at all (`isGeminable`).
    private static func voicedOnsetException(_ counterKana: String) -> Bool {
        guard let first = counterKana.first else { return false }
        return ["ば", "び", "ぶ", "べ", "ぼ"].contains(String(first))
    }

    /// The written form a counter takes after the geminating っ: a は-row
    /// onset voices to the p-series (八+分 → はっぷん), matching how
    /// `KanaRomaji` realizes the sound. ば行 onsets never geminate
    /// (`voicedOnsetException`), so they can't reach this.
    private static func postSokuonVoicing(_ kana: String) -> String {
        let voiced = [
            "は": "ぱ", "ひ": "ぴ", "ふ": "ぷ", "へ": "ぺ", "ほ": "ぽ"
        ]
        guard let first = kana.first, let p = voiced[String(first)] else {
            return kana
        }
        return p + kana.dropFirst()
    }

    /// Digit runs whose counter readings the dictionary can't see, in kana
    /// (the old heuristics' table transliterated): "600" → ろっぴゃく so
    /// 600回 fuses to ろっぴゃっかい. Runs outside the table (123, 2026)
    /// stay unannotated.
    private static let digitReadings: [String: String] = [
        "1": "いち", "2": "に", "3": "さん", "4": "よん", "5": "ご",
        "6": "ろく", "7": "なな", "8": "はち", "9": "きゅう", "10": "じゅう",
        "20": "にじゅう", "30": "さんじゅう", "40": "よんじゅう", "50": "ごじゅう",
        "60": "ろくじゅう", "70": "ななじゅう", "80": "はちじゅう", "90": "きゅうじゅう",
        "100": "ひゃく", "200": "にひゃく", "300": "さんびゃく", "400": "よんひゃく",
        "500": "ごひゃく", "600": "ろっぴゃく", "700": "ななひゃく",
        "800": "はっぴゃく", "900": "きゅうひゃく", "1000": "せん", "10000": "まん"
    ]

    /// Pure numeral surfaces (Arabic or fullwidth digits, kanji numerals):
    /// held back for counter fusion. Engine-fused compounds (一回, 十四日)
    /// contain non-numeral characters and never match.
    private static func isNumeralRun(_ surface: String) -> Bool {
        surface.range(
            of: "^[0-9０-９一二三四五六七八九十百千万]+$", options: .regularExpression
        ) != nil
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
