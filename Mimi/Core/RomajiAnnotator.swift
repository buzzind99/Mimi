import Foundation

/// One rendered run of text plus its optional romaji annotation. The
/// `surface` strings concatenate back to the original text (gaps between
/// tokenizer tokens — punctuation, symbols — become plain runs with a nil
/// `romaji`). A run whose romaji equals its surface (Latin, digits) is
/// self-transcribed; renderers skip annotating those.
final class RomajiSegment {
    var surface: String
    var romaji: String?

    init(surface: String, romaji: String?) {
        self.surface = surface
        self.romaji = romaji
    }
}

/// Produces romaji (Hepburn-style Latin transcription) for Japanese text using
/// the system tokenizer's built-in `LatinTranscription` attribute. No
/// dependencies, no network, no bundled dictionaries.
enum RomajiAnnotator {
    private static let cache = NSCache<NSString, NSString>()
    private static let segmentCache = NSCache<NSString, NSArray>()

    /// Returns space-separated romaji for `text`, or `nil` if nothing
    /// transcribable is present. Cheap (microseconds per sentence) and cached.
    static func romaji(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let cached = cache.object(forKey: trimmed as NSString) {
            return cached as String
        }

        let joined = segments(for: trimmed)?
            .compactMap { $0.romaji }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let joined, !joined.isEmpty else { return nil }
        cache.setObject(joined as NSString, forKey: trimmed as NSString)
        return joined
    }

    /// Returns per-run segments for `text` (surface + romaji), or `nil` for
    /// empty input. Cheap (microseconds per sentence) and cached.
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
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRange(location: 0, length: nsText.length),
            kCFStringTokenizerUnitWord,
            locale
        )

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
            segments.append(RomajiSegment(
                surface: pending.surface,
                romaji: romanize(surface: pending.surface, reading: pending.romaji)
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

            var reading: String
            var endsWithSokuon = false
            if let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription
            ) as? String {
                reading = transcription
                if reading.lowercased().hasSuffix("~tsu") {
                    reading = String(reading.dropLast(4))
                    endsWithSokuon = true
                }
                // The ヴ row is transcribed with a morpheme break
                // (ヴァイオリン → "vu~aiorin"); fuse it into the proper
                // Hepburn spelling ("vaiorin").
                reading = reading.replacingOccurrences(of: "vu~", with: "v")
                reading = reading.replacingOccurrences(of: "~", with: "")
            } else {
                // Digits, Latin runs, symbols: keep the surface text as-is.
                reading = surface
            }

            if let pending = pendingNumber {
                pendingNumber = nil
                if let fused = fuseNumber(number: pending, counterReading: reading) {
                    segments.append(RomajiSegment(surface: pending.surface + surface, romaji: fused))
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
                    reading = ""
                } else if let at = lastTokenIndex {
                    // Next token can't take a geminate (vowel-initial,
                    // digit…): keep the sokuon as a spoken "tsu".
                    segments[at].romaji = (segments[at].romaji ?? "") + "tsu"
                }
            }
            if !reading.isEmpty {
                if !endsWithSokuon,
                   let numReading = numberReading(surface: surface, reading: reading) {
                    pendingNumber = (surface, numReading)
                } else {
                    let segment = RomajiSegment(
                        surface: surface, romaji: romanize(surface: surface, reading: reading)
                    )
                    segments.append(segment)
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
        if let mapped = digitNumberReadings[ascii] { return mapped }
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
           ["sai", "tou", "sen"].contains(where: lower.hasPrefix) {
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
}
