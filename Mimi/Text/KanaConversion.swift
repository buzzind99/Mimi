import Foundation

/// Wapuro-romaji → kana conversion used for furigana, plus the macron
/// normalization shared with romaji transcription. Longest-prefix matching
/// over already-normalized romaji (macrons expanded, "tch"→"cch", particles).
enum KanaConversion {
    /// The tokenizer emits mixed wapuro/macron vowels ("tou", "tawā");
    /// normalize macrons to wapuro spellings for consistency.
    private static let macronExpansion: [Character: String] = [
        "ā": "aa", "ī": "ii", "ū": "uu", "ē": "ee", "ō": "ou",
        "Ā": "Aa", "Ī": "Ii", "Ū": "Uu", "Ē": "Ee", "Ō": "Ou"
    ]

    /// Expands macron vowels to their wapuro spellings ("ō" → "ou").
    static func expandMacrons(_ text: String) -> String {
        text.map { macronExpansion[$0] ?? String($0) }.joined()
    }

    /// Wapuro-romaji → hiragana. Returns nil when any character can't
    /// convert (digits, Latin, stray symbols), so unmappable runs simply
    /// get no furigana.
    static func kana(fromRomaji romaji: String) -> String? {
        guard !romaji.isEmpty else { return nil }
        let expanded = expandMacrons(romaji.lowercased())
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
                // Wapuro writes a moraic ん before a vowel as "nn" ("kanna");
                // the second n starts the next syllable ("na" → な).
                if next == "n" {
                    kana += "ん"
                    i += 1
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
            // Doubled consonant: sokuon ("ikki", "roppyaku"), including the
            // ち-row doubling where っ + ち is spelled "tc…" ("itchi").
            // Doubled vowels and "nn" compose elsewhere.
            if i + 1 < chars.count,
               chars[i + 1] == chars[i]
               || (chars[i] == "t" && chars[i + 1] == "c"),
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
    /// "chi", "tsu"), digraphs (きゃ row), and three-letter foreign
    /// spellings. Sokuon prefixes ("cch"/"tch" for っ + ち-row) are handled
    /// by the doubling branch before this table.
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
