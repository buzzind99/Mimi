import Foundation

/// One rendered run of text plus its optional romaji/kana annotations. The
/// `surface` strings concatenate back to the original text (gaps between
/// tokenizer tokens — punctuation, symbols — become plain runs with nil
/// annotations). A run whose romaji equals its surface (Latin, digits) is
/// self-transcribed; renderers skip annotating those. `furigana` is only
/// populated for kanji-bearing runs whose romaji reverses cleanly to kana.
final class RomajiSegment {
    var surface: String
    var romaji: String?
    var furigana: String?

    init(surface: String, romaji: String?, furigana: String? = nil) {
        self.surface = surface
        self.romaji = romaji
        self.furigana = furigana
    }
}

/// Produces romaji (Hepburn-style Latin transcription) and kana furigana for
/// Japanese text using the system tokenizer's built-in `LatinTranscription`
/// attribute. No dependencies, no network, no bundled dictionaries.
enum RomajiAnnotator {
    private static let segmentCache = NSCache<NSString, NSArray>()

    /// Returns per-run segments for `text` (surface + romaji + furigana), or
    /// `nil` for empty input. Cheap (microseconds per sentence) and cached.
    static func segments(for text: String) -> [RomajiSegment]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let cached = segmentCache.object(forKey: trimmed as NSString) as? [RomajiSegment] {
            return cached
        }

        let result = transcribe(trimmed)
        segmentCache.setObject(result as NSArray, forKey: trimmed as NSString)
        return result
    }

    private static func transcribe(_ text: String) -> [RomajiSegment] {
        let nsText = text as NSString
        let locale = NSLocale(localeIdentifier: "ja_JP") as CFLocale
        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRange(location: 0, length: nsText.length),
            kCFStringTokenizerUnitWord,
            locale
        ) else { return [] }

        var segments: [RomajiSegment] = []
        // Index of the most recent token segment (gaps don't count): sokuon
        // fusion must land on the word, not on intervening punctuation.
        var lastTokenIndex: Int?
        var cursor = 0
        // The tokenizer marks a sokuon that straddles a token boundary with a
        // literal "~tsu" suffix (e.g. みよっか → "miyo~tsu" | "ka"). Consume it
        // and geminate the next token's leading consonant instead.
        var carriesSokuon = false
        // A number token (一, 十, 8, 20…) is held back one token: when the
        // next token is a counter with an unvoiced onset, the pair fuses
        // with sokuon gemination (一回 → "ikkai", 一本 → "ippon") instead
        // of the tokenizer's plain "ichi kai".
        var pendingNumber: (surface: String, romaji: String)?

        func appendNumber(_ pending: (surface: String, romaji: String)) {
            let romaji = romanize(surface: pending.surface, reading: pending.romaji)
            segments.append(RomajiSegment(
                surface: pending.surface,
                romaji: romaji,
                furigana: furigana(surface: pending.surface, romaji: romaji)
            ))
            lastTokenIndex = segments.count - 1
        }

        func appendGap(to end: Int) {
            guard cursor < end else { return }
            let range = NSRange(location: cursor, length: end - cursor)
            let gap = nsText.substring(with: range)
            if gap.trimmingCharacters(in: .whitespaces).isEmpty {
                // Whitespace-only gap: keep word spacing by folding one space
                // into the previous run's surface.
                if let last = segments.last, !gap.isEmpty {
                    last.surface += " "
                }
            } else {
                segments.append(RomajiSegment(surface: gap, romaji: nil))
            }
        }

        while true {
            let tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
            guard tokenType != [] else { break }
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard tokenRange.length > 0 else { break }
            // Don't fuse a held-back number across a gap.
            if pendingNumber != nil, tokenRange.location > cursor {
                appendNumber(pendingNumber!)
                pendingNumber = nil
            }
            appendGap(to: tokenRange.location)

            let surface = nsText.substring(
                with: NSRange(location: tokenRange.location, length: tokenRange.length)
            )

            var (reading, endsWithSokuon) = tokenReading(tokenizer: tokenizer, surface: surface)

            if let pending = pendingNumber {
                pendingNumber = nil
                if let fused = fuseNumber(number: pending, counterReading: reading) {
                    let fusedSurface = pending.surface + surface
                    segments.append(RomajiSegment(
                        surface: fusedSurface,
                        romaji: fused,
                        furigana: furigana(surface: fusedSurface, romaji: fused)
                    ))
                    lastTokenIndex = segments.count - 1
                    carriesSokuon = endsWithSokuon
                    cursor = tokenRange.location + tokenRange.length
                    continue
                }
                // The tokenizer pre-assimilates 本's counter reading to
                // "pon" even where no p-sound occurs (二本 → "ni hon",
                // 三本 → "san bon"); restore the base sound.
                if reading.lowercased().hasPrefix("pon") {
                    let voiced = ["san", "sen", "man"].contains { pending.romaji.hasSuffix($0) }
                    reading = (voiced ? "bon" : "hon") + reading.dropFirst(3)
                }
                appendNumber(pending)
            }

            if carriesSokuon {
                if let doubled = geminate(reading), let at = lastTokenIndex {
                    // Fuse with the previous word — the split is artificial —
                    // absorbing the counter's glyphs into the run's surface.
                    segments[at].romaji = (segments[at].romaji ?? "") + doubled
                    segments[at].surface += surface
                    segments[at].furigana = furigana(
                        surface: segments[at].surface, romaji: segments[at].romaji ?? ""
                    )
                    reading = ""
                } else if let at = lastTokenIndex {
                    // Next token can't take a geminate (vowel-initial,
                    // digit…): keep the sokuon as a spoken "tsu".
                    segments[at].romaji = (segments[at].romaji ?? "") + "tsu"
                    segments[at].furigana = furigana(
                        surface: segments[at].surface, romaji: segments[at].romaji ?? ""
                    )
                }
            }
            if !reading.isEmpty {
                if !endsWithSokuon,
                   let numReading = numberReading(surface: surface, reading: reading)
                {
                    pendingNumber = (surface, numReading)
                } else {
                    let romaji = romanize(surface: surface, reading: reading)
                    segments.append(RomajiSegment(
                        surface: surface,
                        romaji: romaji,
                        furigana: furigana(surface: surface, romaji: romaji)
                    ))
                    lastTokenIndex = segments.count - 1
                }
            }
            carriesSokuon = endsWithSokuon
            cursor = tokenRange.location + tokenRange.length
        }
        if let pending = pendingNumber {
            appendNumber(pending)
            pendingNumber = nil
        }
        if carriesSokuon, let at = lastTokenIndex {
            segments[at].romaji = (segments[at].romaji ?? "") + "tsu"
        }
        appendGap(to: nsText.length)

        return segments
    }

    /// The tokenizer's Latin transcription for the current token, with the
    /// "~tsu" straddling-sokuon marker consumed and the ヴ row's morpheme
    /// break fused ("vu~aiorin" → "vaiorin"). Falls back to the surface text
    /// for tokens without a transcription (digits, Latin runs, symbols).
    private static func tokenReading(
        tokenizer: CFStringTokenizer,
        surface: String
    ) -> (reading: String, endsWithSokuon: Bool) {
        guard let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
            tokenizer, kCFStringTokenizerAttributeLatinTranscription
        ) as? String else {
            return (surface, false)
        }
        var reading = transcription
        var endsWithSokuon = false
        if reading.lowercased().hasSuffix("~tsu") {
            reading = String(reading.dropLast(4))
            endsWithSokuon = true
        }
        reading = reading.replacingOccurrences(of: "vu~", with: "v")
        reading = reading.replacingOccurrences(of: "~", with: "")
        return (reading, endsWithSokuon)
    }

    /// Doubles the leading consonant of `reading` to realize a preceding
    /// sokuon (か→"kka", さ→"ssa", ち→"cchi", ぱ→"ppa"). The は行 and ば行
    /// realize the geminate as the p-series (ひ→"ppiki", ば→"ppai",
    /// ふ→"ppuku"). Returns `nil` when the reading can't take a geminate
    /// (vowel-initial, empty, digits…).
    private static func geminate(_ reading: String) -> String? {
        guard let first = reading.first?.lowercased().first else { return nil }
        if reading.lowercased().hasPrefix("ch") {
            return "c" + reading
        }
        switch first {
        case "h", "b", "f":
            return "pp" + reading.dropFirst()
        case "k", "s", "t", "p", "c":
            return String(reading.first!) + reading
        default:
            return nil
        }
    }

    /// Digits whose readings geminate before a counter, with the reading
    /// used when fusing (1回 → "ikkai", 8歳 → "hassai", 600回 →
    /// "roppyakkai"). Digits outside this table never geminate but still
    /// count as numbers for counter assimilation.
    private static let digitNumberReadings: [String: String] = [
        "1": "ichi", "2": "ni", "3": "san", "4": "yon", "5": "go",
        "6": "roku", "7": "nana", "8": "hachi", "9": "kyuu", "10": "juu",
        "20": "nijuu", "30": "sanjuu", "40": "yonjuu", "50": "gojuu",
        "60": "rokujuu", "70": "nanajuu", "80": "hachijuu", "90": "kyuujuu",
        "100": "hyaku", "200": "nihyaku", "300": "sanbyaku", "400": "yonhyaku",
        "500": "gohyaku", "600": "roppyaku", "700": "nanahyaku",
        "800": "happyaku", "900": "kyuuhyaku", "1000": "sen", "10000": "man"
    ]

    /// Calendar days where the tokenizer splits the native numeral from a
    /// 日 read "ka" (二日 → "futa"|"ka", 六日 → "mui"|"ka", 二十日 →
    /// "hatsu"|"ka"): the stems fused with "ka". The sokuon-fusing days
    /// (三日 → "mi~tsu"|"ka") are handled by the existing sokuon path.
    private static let dateCounterStems: [String: String] = [
        "futa": "futsu", "mi": "mi", "yo": "yo", "itsu": "itsu",
        "mui": "mui", "nana": "nana", "you": "you", "kokono": "kokono",
        "too": "tou", "hatsu": "hatsu"
    ]

    /// 四日 and 七日 keep the plain "nichi" reading of 日; fuse the pair
    /// into the correct calendar forms.
    private static let datePairOverrides: [String: String] = [
        "yon nichi": "yokka", "nana nichi": "nanoka"
    ]

    /// Returns the romaji a number token is held back under, or nil when
    /// the token isn't a number that may fuse with a following counter.
    private static func numberReading(surface: String, reading: String) -> String? {
        guard surface.range(
            of: "^[一二三四五六七八九十百千万0-9]+$", options: .regularExpression
        ) != nil else { return nil }
        let ascii = surface.applyingTransform(.fullwidthToHalfwidth, reverse: false)
            ?? surface
        if let mapped = digitNumberReadings[ascii] {
            return mapped
        }
        return reading.lowercased()
    }

    /// Fuses a held-back number with the next token's reading, returning
    /// the combined romaji, or nil when the pair reads as separate words.
    private static func fuseNumber(
        number: (surface: String, romaji: String),
        counterReading: String
    ) -> String? {
        let lower = counterReading.lowercased()
        guard !lower.isEmpty else { return nil }

        if let fused = datePairOverrides[number.romaji + " " + lower] {
            return fused
        }

        // 二日/五日/…: only the "ka" reading of 日 participates; 三日 and
        // 四日 geminate (mikka, yokka), the rest elide or keep their mora.
        if let stem = dateCounterStems[number.romaji] {
            guard lower == "ka" else { return nil }
            switch number.romaji {
            case "mi", "yo":
                return stem + (geminate("ka") ?? "ka")
            default:
                return stem + "ka"
            }
        }

        guard let stem = geminationStem(of: number.romaji),
              let doubled = geminate(counterReading) else { return nil }
        // Lexical, not phonological: 六歳 "rokusai", 六等 "rokutou" and
        // 六千 "rokusen" keep their plain readings.
        if number.romaji == "roku",
           ["sai", "tou", "sen"].contains(where: lower.hasPrefix)
        {
            return nil
        }
        return stem + doubled
    }

    /// Drops the number's closing mora so the counter can geminate
    /// (ichi → "i", roku → "ro", hyaku → "hya", juu → "ju").
    private static func geminationStem(of romaji: String) -> String? {
        for suffix in ["chi", "tsu", "ku"] where romaji.hasSuffix(suffix) {
            return String(romaji.dropLast(suffix.count))
        }
        // じゅう geminates to じゅっ: only the trailing vowel elides
        // (juu → "ju", nijuu → "niju").
        if romaji.hasSuffix("juu") {
            return String(romaji.dropLast(1))
        }
        return nil
    }

    /// Common lexicalized greetings where the topic particle is fused into a
    /// single dictionary token and the tokenizer's transcription is wrong,
    /// plus established English loanword spellings (抹茶 → "matcha").
    private static let lexicalOverrides = [
        "こんにちは": "konnichiwa",
        "こんばんは": "konbanwa",
        "抹茶": "matcha",
        // Fused by the tokenizer under its family reading ("mimoto").
        "三本": "sanbon"
    ]

    /// The tokenizer emits mixed wapuro/macron vowels ("tou", "tawā");
    /// normalize macrons to wapuro spellings for consistency.
    private static let macronExpansion: [Character: String] = [
        "ā": "aa", "ī": "ii", "ū": "uu", "ē": "ee", "ō": "ou",
        "Ā": "Aa", "Ī": "Ii", "Ū": "Uu", "Ē": "Ee", "Ō": "Ou"
    ]

    private static func romanize(surface: String, reading: String) -> String {
        if let overridden = lexicalOverrides[surface] {
            return overridden
        }
        let lower = reading.lowercased()
        // The tokenizer spells っち as "tch" (めっちゃ→"metcha"); normalize to
        // the doubled-consonant "cch" (meccha, kocchi, macchi). ん + な行 is
        // written "nn" in Hepburn (かん'な → kanna), not with an apostrophe;
        // ん + vowels/や行 keeps the apostrophe (まん'いん → man'in).
        let sokuonCorrected = reading
            .replacingOccurrences(of: "tch", with: "cch")
            .replacingOccurrences(of: "n'n", with: "nn")
        let particleCorrected: String
        switch surface {
        case "は":
            particleCorrected = lower == "ha" ? "wa" : sokuonCorrected
        case "へ":
            particleCorrected = lower == "he" ? "e" : sokuonCorrected
        case "を":
            particleCorrected = lower == "wo" ? "o" : sokuonCorrected
        default:
            particleCorrected = sokuonCorrected
        }
        return particleCorrected.map { macronExpansion[$0] ?? String($0) }
            .joined()
    }

    /// Kana furigana for a run: only kanji-bearing surfaces are annotated
    /// (kana, katakana loanwords and particles need no furigana), and only
    /// when the run's romaji reverses cleanly to kana (fused digit+counter
    /// runs containing digits, or stray symbols, stay unannotated).
    private static func furigana(surface: String, romaji: String) -> String? {
        guard containsKanji(surface) else { return nil }
        return kanaReading(from: romaji)
    }

    private static func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00 ... 0x9FFF).contains(scalar.value)
                || (0x3400 ... 0x4DBF).contains(scalar.value)
                || scalar.value == 0x3005 // 々
        }
    }

    /// Wapuro-romaji → hiragana. Longest-prefix matching over the annotator's
    /// already-normalized romaji (macrons expanded, "tch"→"cch", particles).
    /// Returns nil when any character can't convert (digits, Latin, stray
    /// symbols), so unmappable runs simply get no furigana.
    private static func kanaReading(from romaji: String) -> String? {
        guard !romaji.isEmpty else { return nil }
        let expanded = romaji.lowercased()
            .map { macronExpansion[$0] ?? String($0) }
            .joined()
        let chars = Array(expanded)
        var kana = ""
        var i = 0
        while i < chars.count {
            if i + 2 < chars.count, let mapped = kanaTriples[String(chars[i ... i + 2])] {
                kana += mapped
                i += 3
                continue
            }
            if i + 1 < chars.count, let mapped = kanaPairs[String(chars[i ... i + 1])] {
                kana += mapped
                i += 2
                continue
            }
            if chars[i] == "n" {
                let isFinal = i + 1 == chars.count
                let next = isFinal ? nil : chars[i + 1]
                if isFinal || next == "'" {
                    kana += "ん"
                    i += next == "'" ? 2 : 1
                    continue
                }
                // Wapuro writes a moraic ん before a vowel as "nn" ("kanna").
                if next == "n" {
                    kana += "ん"
                    i += 2
                    continue
                }
                // ん before a consonant (んた, んで…), but "ny" belongs to a
                // digraph that failed to match — unknown sequence.
                if let next, !"aiueoy".contains(next) {
                    kana += "ん"
                    i += 1
                    continue
                }
                return nil
            }
            // Doubled consonant: sokuon ("ikki", "roppyaku"). Doubled vowels
            // and "nn" compose elsewhere.
            if i + 1 < chars.count,
               chars[i + 1] == chars[i],
               !"aiueon".contains(chars[i])
            {
                kana += "っ"
                i += 1
                continue
            }
            guard let mapped = kanaSingles[String(chars[i])] else { return nil }
            kana += mapped
            i += 1
        }
        return kana
    }

    /// Three-character forms: three-letter one-mora spellings ("shi",
    /// "chi", "tsu"), digraphs (きゃ row), geminate+digraph ("cchi" for
    /// っち), and three-letter foreign spellings.
    private static let kanaTriples: [String: String] = [
        "shi": "し", "chi": "ち", "tsu": "つ",
        "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
        "sha": "しゃ", "shu": "しゅ", "she": "しぇ", "sho": "しょ",
        "cha": "ちゃ", "chu": "ちゅ", "che": "ちぇ", "cho": "ちょ",
        "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
        "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
        "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
        "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
        "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
        "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
        "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
        "cch": "っち", "tch": "っち",
        "tsa": "つぁ", "tsi": "つぃ", "tse": "つぇ", "tso": "つぉ"
    ]

    /// Two-character spellings: CV pairs and two-letter foreign forms.
    /// Long vowels need no entries ("tou" = と+う).
    private static let kanaPairs: [String: String] = [
        "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
        "sa": "さ", "si": "し", "su": "す", "se": "せ", "so": "そ",
        "ta": "た", "te": "て", "to": "と", "ti": "てぃ", "tu": "とぅ",
        "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
        "ha": "は", "hi": "ひ", "fu": "ふ", "he": "へ", "ho": "ほ",
        "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
        "ya": "や", "yu": "ゆ", "yo": "よ",
        "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
        "wa": "わ", "wi": "うぃ", "we": "うぇ", "wo": "を",
        "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
        "za": "ざ", "zi": "じ", "ji": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
        "da": "だ", "de": "で", "do": "ど", "di": "でぃ", "du": "どぅ",
        "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
        "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
        "vu": "ゔ", "ye": "いぇ",
        "ja": "じゃ", "ju": "じゅ", "je": "じぇ", "jo": "じょ",
        "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
        "va": "ゔぁ", "vi": "ゔぃ", "ve": "ゔぇ", "vo": "ゔぉ"
    ]

    private static let kanaSingles: [String: String] = [
        "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
        "n": "ん"
    ]
}
