import Foundation

// MARK: - Numeral → counter fusion

/// The numeral→counter fusion machinery behind `ReadingAnnotator`: numeral
/// runs held back for fusion (`PendingNumber`), the fusion decision table
/// (`fuse`), and the kana tables for the irregular readings the dictionary
/// can't express. The surface-level transcription pass lives in
/// `ReadingAnnotator.swift`.
extension ReadingAnnotator {

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

    /// Emits a held-back numeral run as its own segment, plus any whitespace
    /// it swallowed as a plain run. Digit runs without a table reading (123,
    /// 2026) stay unannotated.
    func appendNumber(
        _ pending: PendingNumber, into segments: inout [ReadingSegment]
    ) {
        var held = pending
        Self.resolveDigits(into: &held)
        guard !held.unresolved, !held.kana.isEmpty else {
            segments.append(ReadingSegment(
                surface: held.surface, romaji: held.surface, furigana: nil
            ))
            appendGap(held.gap, into: &segments)
            return
        }
        append(surface: held.surface, kana: held.kana, into: &segments)
        appendGap(held.gap, into: &segments)
    }

    /// Re-emits whitespace a held run absorbed (fused surfaces fold it into
    /// their own surface instead) so surfaces still concatenate back.
    private func appendGap(
        _ gap: String, into segments: inout [ReadingSegment]
    ) {
        guard !gap.isEmpty else { return }
        segments.append(ReadingSegment(surface: gap, romaji: gap, furigana: nil))
    }

    func flush(
        _ pending: inout PendingNumber?, into segments: inout [ReadingSegment]
    ) {
        guard let held = pending else { return }
        pending = nil
        appendNumber(held, into: &segments)
    }

    /// A numeral run held back for counter fusion: the consumed surface plus
    /// its kana reading so far. Digits accumulate as a normalized run and
    /// resolve through the digit table when the run completes.
    struct PendingNumber {
        var surface: String
        var digits = "" // fullwidth-normalized digit run awaiting lookup
        var kana = "" // accumulated kana of resolved parts
        var unresolved = false // a digit run with no table reading poisons the whole
        var gap = "" // whitespace the ASR inserted between the run and what follows

        init(
            surface: String, digits: String = "", kana: String = "",
            unresolved: Bool = false, gap: String = ""
        ) {
            self.surface = surface
            self.digits = digits
            self.kana = kana
            self.unresolved = unresolved
            self.gap = gap
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
    static func accumulate(
        _ token: DictionaryToken, surface: String, into pending: inout PendingNumber?
    ) {
        let ascii = surface.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? surface
        if ascii.range(of: "^[0-9]+$", options: .regularExpression) != nil {
            if var held = pending {
                held.surface += held.gap
                held.gap = ""
                held.surface += surface
                held.digits += ascii
                pending = held
            } else {
                pending = PendingNumber(surface: surface, digits: ascii)
            }
            return
        }
        let kana = token.reading
        if var held = pending {
            held.surface += held.gap
            held.gap = ""
            held.surface += surface
            resolveDigits(into: &held)
            if let kana {
                held.kana += kana
            } else {
                held.unresolved = true
            }
            pending = held
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
    func fuse(
        _ pending: inout PendingNumber?, with token: DictionaryToken, surface: String,
        into segments: inout [ReadingSegment]
    ) -> Bool {
        guard var held = pending else { return false }
        let fusedSurface = held.surface + held.gap + surface

        // Irregular calendar days own the whole reading: the digit-run table
        // fires before resolution (Arabic runs the digit table can't resolve,
        // 14日), the kana table after (kanji numeral runs, 二日/二十日).
        if surface == "日", let date = Self.digitDateReadings[held.digits] {
            pending = nil
            append(surface: fusedSurface, kana: date, into: &segments)
            return true
        }
        Self.resolveDigits(into: &held)
        if surface == "日", let date = Self.kanaDateReadings[held.kana] {
            pending = nil
            append(surface: fusedSurface, kana: date, into: &segments)
            return true
        }
        // Months and hours take lexical number readings the digit table
        // can't express (4月 → しがつ, 9時 → くじ): swap the number's kana in.
        if let replacement = Self.lexicalNumberReading(kana: held.kana, counter: surface) {
            held.kana = replacement
        }
        // The counter reading is forced where the dictionary's first reading
        // is the standalone word (月 → つき, 時 → とき, 本 → もと); counters
        // read がつ/じ/ほん after a number.
        let reading = Self.forcedCounterReadings[surface] ?? token.reading

        // 年 after a number is the counter year (２年 → にねん), never the
        // standalone "toshi" reading, and it never geminates. Unresolvable
        // runs (2026年) keep their own segments.
        if surface == "年" {
            pending = nil
            if !held.unresolved, !held.kana.isEmpty {
                append(surface: fusedSurface, kana: held.kana + "ねん", into: &segments)
            } else {
                appendNumber(held, into: &segments)
                append(surface: surface, kana: "ねん", into: &segments)
            }
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
            append(surface: fusedSurface, kana: people, into: &segments)
            return true
        }
        // Fusion needs a readable number and a word-like counter (kanji or
        // katakana). Hiragana after a number is a particle or auxiliary
        // (2は, 3が) — it keeps its own segment and its particle overrides.
        guard !held.unresolved, !held.kana.isEmpty, let reading,
              Self.isCounterCandidate(surface)
        else {
            pending = nil
            appendNumber(held, into: &segments)
            return false
        }
        // Geminating fusion: the number keeps its stem and the counter takes
        // a sokuon (ろく+かい → ろっかい), except where the plain reading is
        // lexical (六 + 歳/等/千) or the counter's onset can't take a sokuon
        // (ば行 keeps the plain reading, 一番 → いちばん).
        if !Self.rokuException(numberKana: held.kana, counterKana: reading),
           !Self.voicedOnsetException(reading),
           let stem = Self.geminationStem(of: held.kana), Self.isGeminable(reading)
        {
            pending = nil
            append(
                surface: fusedSurface,
                kana: stem + "っ" + Self.postSokuonVoicing(reading),
                into: &segments
            )
            return true
        }
        // Plain fusion: numbers that don't geminate concatenate with the
        // counter (9月 → くがつ, 三人 → さんにん), a ん-ender voicing the
        // は行 counter (さん+ふん → さんぷん, よん+ほん → よんぼん).
        pending = nil
        append(
            surface: fusedSurface,
            kana: Self.voiceAcrossN(numberKana: held.kana, counterKana: reading),
            into: &segments
        )
        return true
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
    /// outside the table (三人, 十人, 二十人) read regularly and take the
    /// plain-fusion path.
    private static let peopleCounterReadings: [String: String] = [
        "いち": "ひとり", "に": "ふたり", "よん": "よにん"
    ]

    /// Irregular calendar-day readings keyed by the raw digit run, consulted
    /// before resolution: covers Arabic runs the digit table can't resolve
    /// (14日, 24日). 1日 through 10日 (ついたち…とおか) plus 14日/20日/24日;
    /// other runs read regularly through plain fusion (15日 → じゅうごにち).
    private static let digitDateReadings: [String: String] = [
        "1": "ついたち", "2": "ふつか", "3": "みっか", "4": "よっか", "5": "いつか",
        "6": "むいか", "7": "なのか", "8": "ようか", "9": "ここのか", "10": "とおか",
        "14": "じゅうよっか", "20": "はつか", "24": "にじゅうよっか"
    ]

    /// The same irregular days keyed by the resolved number kana, consulted
    /// after resolution: covers kanji numeral runs the tokenizer splits
    /// (二+日 → ふつか, 二十+日 → はつか, 十四+日 → じゅうよっか).
    private static let kanaDateReadings: [String: String] = [
        "いち": "ついたち", "に": "ふつか", "さん": "みっか", "よん": "よっか",
        "ご": "いつか", "ろく": "むいか", "なな": "なのか", "はち": "ようか",
        "きゅう": "ここのか", "じゅう": "とおか", "にじゅう": "はつか",
        "じゅうよん": "じゅうよっか", "にじゅうよん": "にじゅうよっか"
    ]

    /// Lexical number readings for the month counter, keyed by the resolved
    /// number kana: 4月/7月/9月 read しがつ/しちがつ/くがつ — the table's
    /// よん/なな/きゅう never occur before 月.
    private static let monthReadings: [String: String] = [
        "よん": "し", "なな": "しち", "きゅう": "く"
    ]

    /// Same pattern for the hour counter: 4時/7時/9時 read よじ/しちじ/くじ.
    private static let hourReadings: [String: String] = [
        "よん": "よ", "なな": "しち", "きゅう": "く"
    ]

    /// Month/hour table dispatch: which counter takes a lexical number
    /// reading, and from which table.
    private static func lexicalNumberReading(
        kana: String, counter: String
    ) -> String? {
        switch counter {
        case "月": return monthReadings[kana]
        case "時": return hourReadings[kana]
        default: return nil
        }
    }

    /// Counter readings forced over the dictionary's first reading when a
    /// number precedes: 月 and 時 resolve to the standalone つき/とき entries
    /// (the counter reads がつ/じ), and 本's shared entry's first reading is
    /// もと (the counter reads ほん).
    private static let forcedCounterReadings = ["月": "がつ", "時": "じ", "本": "ほん"]

    /// Whether a token following a held number can be a counter: kanji and
    /// katakana tokens are (月, 匹, キロ). Hiragana-only tokens are particles
    /// or auxiliaries (は, が, ました) and never fuse — they must keep their
    /// own segments so particle/function-word overrides still apply.
    private static func isCounterCandidate(_ surface: String) -> Bool {
        surface.unicodeScalars.contains {
            KanaClassification.isKanji($0) || KanaClassification.isKatakana($0)
        }
    }

    /// Voicing across a number's moraic ん (さん/よん/せん/まん): a following
    /// は行 counter voices — to the p-series for the assimilating counters
    /// (ふん 分, ほ 歩, はつ 発: さんぷん, さんぽ, さんぱつ) and to the rendaku
    /// b-series for the rest (ほん 本, ひき 匹, はこ 箱: よんぼん, さんびき,
    /// さんばん). Any other counter passes through unchanged.
    private static func voiceAcrossN(numberKana: String, counterKana: String) -> String {
        guard numberKana.hasSuffix("ん"),
              let first = counterKana.first,
              "はひふへほ".contains(String(first))
        else { return numberKana + counterKana }
        // 歩 reads as bare ほ while 本 is ほん — the exact match separates
        // the p-voiced 歩 from the rendaku 本.
        let toP = counterKana == "ほ"
            || counterKana.hasPrefix("ふ") || counterKana.hasPrefix("はつ")
        let voiced = toP
            ? ["は": "ぱ", "ひ": "ぴ", "ふ": "ぷ", "へ": "ぺ", "ほ": "ぽ"]
            : ["は": "ば", "ひ": "び", "ふ": "ぶ", "へ": "べ", "ほ": "ぼ"]
        guard let onset = voiced[String(first)] else {
            return numberKana + counterKana
        }
        return numberKana + onset + counterKana.dropFirst()
    }

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
    static func isNumeralRun(_ surface: String) -> Bool {
        surface.range(
            of: "^[0-9０-９一二三四五六七八九十百千万]+$", options: .regularExpression
        ) != nil
    }
}
