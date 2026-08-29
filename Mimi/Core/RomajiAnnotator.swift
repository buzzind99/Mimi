import Foundation

/// Produces romaji (Hepburn-style Latin transcription) for Japanese text using
/// the system tokenizer's built-in `LatinTranscription` attribute. No
/// dependencies, no network, no bundled dictionaries.
enum RomajiAnnotator {
    private static let cache = NSCache<NSString, NSString>()

    /// Returns space-separated romaji for `text`, or `nil` if nothing
    /// transcribable is present. Cheap (microseconds per sentence) and cached.
    static func romaji(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let cached = cache.object(forKey: trimmed as NSString) {
            return cached as String
        }

        let result = transcribe(trimmed)
        if let result {
            cache.setObject(result as NSString, forKey: trimmed as NSString)
        }
        return result
    }

    private static func transcribe(_ text: String) -> String? {
        let locale = NSLocale(localeIdentifier: "ja_JP") as CFLocale
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRange(location: 0, length: (text as NSString).length),
            kCFStringTokenizerUnitWord,
            locale)

        var parts: [String] = []
        // The tokenizer marks a sokuon that straddles a token boundary with a
        // literal "~tsu" suffix (e.g. みよっか → "miyo~tsu" | "ka"). Consume it
        // and geminate the next token's leading consonant instead.
        var carriesSokuon = false
        while true {
            let tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
            guard tokenType != [] else { break }
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard tokenRange.length > 0 else { break }

            let surface = (text as NSString).substring(
                with: NSRange(location: tokenRange.location, length: tokenRange.length))

            var reading: String
            var endsWithSokuon = false
            if let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                reading = transcription
                if reading.lowercased().hasSuffix("~tsu") {
                    reading = String(reading.dropLast(4))
                    endsWithSokuon = true
                }
                reading = reading.replacingOccurrences(of: "~", with: "")
            } else {
                // Digits, Latin runs, symbols: keep the surface text as-is.
                reading = surface
            }

            if carriesSokuon {
                if let doubled = geminate(reading) {
                    reading = doubled
                    // Fuse with the previous token — the split is artificial.
                    if let last = parts.last {
                        parts[parts.count - 1] = last + reading
                        reading = ""
                    }
                } else {
                    // Next token can't take a geminate (vowel-initial, digit…):
                    // keep the sokuon as a spoken "tsu".
                    parts.append("tsu")
                }
            }
            if !reading.isEmpty {
                parts.append(romanize(surface: surface, reading: reading))
            }
            carriesSokuon = endsWithSokuon
        }
        if carriesSokuon {
            parts.append("tsu")
        }

        let joined = parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    /// Doubles the leading consonant of `reading` to realize a preceding
    /// sokuon (か→"kka", さ→"ssa", ち→"cchi", ぱ→"ppa"). Returns `nil` when
    /// the reading can't take a geminate (vowel-initial, empty, digits…).
    private static func geminate(_ reading: String) -> String? {
        guard let first = reading.first else { return nil }
        if reading.lowercased().hasPrefix("ch") {
            return "c" + reading
        }
        guard "kstpc".contains(String(first).lowercased()) else { return nil }
        return String(first) + reading
    }

    /// Common lexicalized greetings where the topic particle is fused into a
    /// single dictionary token and the tokenizer's transcription is wrong,
    /// plus established English loanword spellings (抹茶 → "matcha").
    private static let lexicalOverrides = [
        "こんにちは": "konnichiwa",
        "こんばんは": "konbanwa",
        "抹茶": "matcha",
    ]

    /// The tokenizer emits mixed wapuro/macron vowels ("tou", "tawā");
    /// normalize macrons to wapuro spellings for consistency.
    private static let macronExpansion: [Character: String] = [
        "ā": "aa", "ī": "ii", "ū": "uu", "ē": "ee", "ō": "ou",
        "Ā": "Aa", "Ī": "Ii", "Ū": "Uu", "Ē": "Ee", "Ō": "Ou",
    ]

    private static func romanize(surface: String, reading: String) -> String {
        if let overridden = lexicalOverrides[surface] {
            return overridden
        }
        let lower = reading.lowercased()
        // The tokenizer spells っち as "tch" (めっちゃ→"metcha"); normalize to
        // the doubled-consonant "cch" (meccha, kocchi, macchi).
        let sokuonCorrected = reading.replacingOccurrences(of: "tch", with: "cch")
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
