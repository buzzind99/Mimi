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
/// furigana for Japanese text from the dictionary tokenizer's JMdict-backed
/// kana readings (`DictionaryEngine`), plus a numeral→counter fusion pass in
/// kana space so Arabic-digit counters read correctly (`600回` →
/// "roppyakkai"). The dictionary may still be building on first launch;
/// every failure degrades to plain text.
final class ReadingAnnotator {
    /// The process-wide annotator backing the static entry point.
    static let shared = ReadingAnnotator()

    private let cache = NSCache<NSString, NSArray>()
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

        for token in tokens {
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
            } else if !fuse(&pending, with: token, surface: surface, into: &segments) {
                appendToken(token, surface: surface, into: &segments)
            }
        }
        flush(&pending, into: &segments)
        appendSpan(from: cursor, to: scalars.count, of: scalars, into: &segments)
        return segments
    }

    /// Emits a non-numeral token: the selected dictionary reading converted
    /// to romaji (with particle and lexical overrides), furigana only for
    /// kanji-bearing surfaces. Entry-less tokens (names, rare ideographs,
    /// punctuation, bare Latin) stay self-transcribed and unannotated.
    private func appendToken(
        _ token: DictionaryToken, surface: String, into segments: inout [ReadingSegment]
    ) {
        guard let reading = Self.selectReading(for: token) else {
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
            furigana: Self.containsKanji(surface) ? reading : nil
        ))
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
            furigana: Self.containsKanji(surface) ? kana : nil
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
    /// normalized glyphs, kanji numerals contribute their entry kana
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
        let kana = selectReading(for: token)
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
        let reading = Self.selectReading(for: token)

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
        // Generic fusion: the number keeps its geminating stem and the
        // counter takes a sokuon (ろく+かい → ろっかい), except where the
        // plain reading is lexical (六 + 歳/等/千).
        if !held.unresolved, !held.kana.isEmpty, let reading,
           !Self.rokuException(numberKana: held.kana, counterKana: reading),
           let stem = Self.geminationStem(of: held.kana), Self.isGeminable(reading)
        {
            pending = nil
            append(surface: held.surface + surface, kana: stem + "っ" + reading, into: &segments)
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

    /// 六 keeps its plain reading before 歳/等/千 (ろくさい/ろくとう/ろくせん):
    /// the fusion must not produce ろっさい.
    private static func rokuException(numberKana: String, counterKana: String) -> Bool {
        numberKana == "ろく" && ["さい", "とう", "せん"].contains { counterKana.hasPrefix($0) }
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

    // MARK: - Reading selection

    /// Picks the kana reading to display for a token
    /// (NOTES-dictionary-preflight.md §5): when the surface contains kana,
    /// prefer the reading that agrees with it (こっち → こっち not こちら,
    /// いい天気 → いいてんき not よいてんき); otherwise the highest-priority
    /// reading that isn't a search-only form, else the first listed.
    private static func selectReading(for token: DictionaryToken) -> String? {
        guard let readings = token.dictionaryEntry?.kanaReadings, !readings.isEmpty else {
            return nil
        }
        if token.text.unicodeScalars.contains(where: isKana) {
            let agreeing = readings.filter { agreesWithSurface($0.text, surface: token.text) }
            if !agreeing.isEmpty {
                return best(of: agreeing).text
            }
        }
        return best(of: readings).text
    }

    /// Readings whose text agrees with the surface's own kana: every kana in
    /// the surface must appear literally, in order, in the reading; all
    /// other characters (kanji, okurigana gaps) match freely.
    private static func agreesWithSurface(_ reading: String, surface: String) -> Bool {
        var pattern = "^"
        for scalar in surface.unicodeScalars {
            pattern += isKana(scalar) ? NSRegularExpression.escapedPattern(for: String(scalar)) : ".*"
        }
        pattern += "$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(reading.startIndex..., in: reading)
        return regex.firstMatch(in: reading, range: range) != nil
    }

    /// The best reading of a list: the first of the highest JMdict priority
    /// among readings that aren't search-only forms; if all are search-only,
    /// the first reading.
    private static func best(
        of readings: [DictionaryToken.KanaReading]
    ) -> DictionaryToken.KanaReading {
        let eligible = readings.filter { $0.info?.contains("search-only") != true }
        let pool = eligible.isEmpty ? readings : eligible
        var winner = pool[0]
        for candidate in pool.dropFirst() where priorityScore(candidate) > priorityScore(winner) {
            winner = candidate
        }
        return winner
    }

    /// JMdict priority ranking: ichi1 > spec1 > gai1 > news1/nfXX > none.
    private static func priorityScore(_ reading: DictionaryToken.KanaReading) -> Int {
        guard let tags = reading.priority?.split(separator: ",") else { return 0 }
        return tags.map { tag in
            switch tag.trimmingCharacters(in: .whitespaces) {
            case "ichi1": return 4
            case "spec1": return 3
            case "gai1": return 2
            case "news1": return 1
            default:
                if tag.hasPrefix("nf"), Int(tag.dropFirst(2)) != nil {
                    return 1
                }
                return 0
            }
        }.max() ?? 0
    }

    // MARK: - Overrides

    /// Topic/directional/object particles read by function, not by their
    /// dictionary reading (は → "wa", not "ha").
    private static let particleRomaji = ["は": "wa", "へ": "e", "を": "o"]

    /// Established spellings the kana conversion can't produce: the
    /// greetings' fused particle (は → "ha" mechanically, "wa" by
    /// convention; keyed by reading so the fused kanji forms 今日は and
    /// 今晩は inherit it) and 抹茶's maccha → matcha.
    private static let lexicalRomaji = [
        "こんにちは": "konnichiwa", "こんばんは": "konbanwa", "まっちゃ": "matcha"
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

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041 ... 0x309F).contains(scalar.value)
            || (0x30A1 ... 0x30FF).contains(scalar.value)
    }

    private static func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00 ... 0x9FFF).contains(scalar.value)
                || (0x3400 ... 0x4DBF).contains(scalar.value)
                || scalar.value == 0x3005 // 々
        }
    }
}
