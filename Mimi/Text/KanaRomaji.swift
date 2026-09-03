import Foundation

/// Kana → wapuro-romaji conversion for dictionary readings — the forward,
/// unambiguous direction (kana readings carry no segmentation ambiguity,
/// unlike the reverse). Emits the exact style the annotation suite pins:
/// wapuro long vowels ("tou", "juu", "koohii" via ー), Hepburn consonants
/// ("sha", "chi", "tsu"), geminated sokuons ("ikkai"; っ + ち-row as "cch…";
/// っ + は/ば-row realized as the p-series) and moraic ん as "n" except
/// before a vowel/y-row ("man'in"). Returns nil when any character is
/// unmappable (kanji, Latin, digits, symbols), so callers fall back to the
/// surface.
enum KanaRomaji {
    /// Converts kana (hiragana or katakana) to lowercase wapuro romaji.
    static func romaji(fromKana kana: String) -> String? {
        // NFC so decomposed voicing marks (か + ゛) map like precomposed が.
        let normalized = kana.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return nil }
        let chars = Array(normalized)
        var romaji = ""
        // The last vowel emitted; ー (choonpu) repeats it (コー → "koo").
        var lastVowel: Character?
        var i = 0
        while i < chars.count {
            if i + 1 < chars.count, let mapped = digraphs[String(chars[i ... i + 1])] {
                romaji += mapped
                lastVowel = mapped.last
                i += 2
                continue
            }
            let char = chars[i]
            if char == "っ" || char == "ッ" {
                if let (geminated, consumed) = geminatedSokuon(at: i, in: chars) {
                    romaji += geminated
                    lastVowel = geminated.last
                    i += consumed
                } else {
                    // No gemination possible (vowel, unmappable mora, end):
                    // the sokuon is spoken as a standalone "tsu" (おっ →
                    // "otsu", trailing 言っ → "itsu"). A spoken "tsu" can't
                    // be prolonged, so a following ー must fail rather than
                    // repeat a stale vowel.
                    romaji += "tsu"
                    lastVowel = nil
                    i += 1
                }
                continue
            }
            if char == "ー" {
                guard let vowel = lastVowel else { return nil }
                romaji.append(vowel)
                i += 1
                continue
            }
            if char == "ん" || char == "ン" {
                romaji += moraicN(after: i + 1 < chars.count ? chars[i + 1] : nil)
                // ん can't be prolonged; a following ー must fail rather than
                // repeat the previous mora's vowel.
                lastVowel = nil
                i += 1
                continue
            }
            guard let mapped = singles[String(char)] else { return nil }
            romaji += mapped
            lastVowel = mapped.last
            i += 1
        }
        return romaji
    }

    /// Two-kana combinations: y-digraphs (きゃ → "kya"), the foreign forms
    /// (ファ → "fa", ヴァ → "va", ティ → "ti", とぅ → "tu", ウォ → "wo")
    /// and the ち-row spellings (ちゃ → "cha"). Long vowels need no entries
    /// (とう = と + う).
    private static let digraphs: [String: String] = [
        "きゃ": "kya", "きゅ": "kyu", "きょ": "kyo",
        "ぎゃ": "gya", "ぎゅ": "gyu", "ぎょ": "gyo",
        "しゃ": "sha", "しゅ": "shu", "しぇ": "she", "しょ": "sho",
        "じゃ": "ja", "じゅ": "ju", "じぇ": "je", "じょ": "jo",
        "ぢゃ": "ja", "ぢゅ": "ju", "ぢょ": "jo",
        "ちゃ": "cha", "ちゅ": "chu", "ちぇ": "che", "ちょ": "cho",
        "にゃ": "nya", "にゅ": "nyu", "にょ": "nyo",
        "ひゃ": "hya", "ひゅ": "hyu", "ひょ": "hyo",
        "みゃ": "mya", "みゅ": "myu", "みょ": "myo",
        "りゃ": "rya", "りゅ": "ryu", "りょ": "ryo",
        "びゃ": "bya", "びゅ": "byu", "びょ": "byo",
        "ぴゃ": "pya", "ぴゅ": "pyu", "ぴょ": "pyo",
        "ふぁ": "fa", "ふぃ": "fi", "ふぇ": "fe", "ふぉ": "fo",
        "ふゃ": "fya", "ふゅ": "fyu", "ふょ": "fyo",
        "ゔぁ": "va", "ゔぃ": "vi", "ゔぇ": "ve", "ゔぉ": "vo",
        "てぃ": "ti", "てゅ": "tyu", "とぅ": "tu",
        "でぃ": "di", "でゅ": "dyu", "どぅ": "du",
        "うぃ": "wi", "うぇ": "we", "うぉ": "wo",
        "いぇ": "ye",
        "つぁ": "tsa", "つぃ": "tsi", "つぇ": "tse", "つぉ": "tso",
        "ヴァ": "va", "ヴィ": "vi", "ヴェ": "ve", "ヴォ": "vo",
        "ヴャ": "vya", "ヴュ": "vyu", "ヴョ": "vyo",
        "ファ": "fa", "フィ": "fi", "フェ": "fe", "フォ": "fo",
        "フャ": "fya", "フュ": "fyu", "フョ": "fyo",
        "ティ": "ti", "テュ": "tyu", "トゥ": "tu",
        "ディ": "di", "デュ": "dyu", "ドゥ": "du",
        "ウィ": "wi", "ウェ": "we", "ウォ": "wo",
        "イェ": "ye",
        "シェ": "she", "チェ": "che", "ジェ": "je",
        "ツァ": "tsa", "ツィ": "tsi", "ツェ": "tse", "ツォ": "tso",
        "クァ": "kwa", "クィ": "kwi", "クェ": "kwe", "クォ": "kwo",
        "クヮ": "kwa"
    ]

    /// Single kana. し/ち/つ use their Hepburn spellings; ぢ/づ voice to
    /// "ji"/"zu"; を keeps its historical "wo" (the particle reading is the
    /// annotator's concern, not the converter's). ん/ン are absent — moraic-n
    /// handling is context-dependent; small kana map to their plain forms.
    private static let singles: [String: String] = [
        "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
        "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
        "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
        "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
        "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
        "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
        "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
        "や": "ya", "ゆ": "yu", "よ": "yo",
        "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
        "わ": "wa", "を": "wo",
        "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
        "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
        "だ": "da", "ぢ": "ji", "づ": "zu", "で": "de", "ど": "do",
        "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
        "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
        "ゔ": "vu",
        "ゐ": "wi", "ゑ": "we",
        "ア": "a", "イ": "i", "ウ": "u", "エ": "e", "オ": "o",
        "カ": "ka", "キ": "ki", "ク": "ku", "ケ": "ke", "コ": "ko",
        "サ": "sa", "シ": "shi", "ス": "su", "セ": "se", "ソ": "so",
        "タ": "ta", "チ": "chi", "ツ": "tsu", "テ": "te", "ト": "to",
        "ナ": "na", "ニ": "ni", "ヌ": "nu", "ネ": "ne", "ノ": "no",
        "ハ": "ha", "ヒ": "hi", "フ": "fu", "ヘ": "he", "ホ": "ho",
        "マ": "ma", "ミ": "mi", "ム": "mu", "メ": "me", "モ": "mo",
        "ヤ": "ya", "ユ": "yu", "ヨ": "yo",
        "ラ": "ra", "リ": "ri", "ル": "ru", "レ": "re", "ロ": "ro",
        "ワ": "wa", "ヲ": "wo",
        "ガ": "ga", "ギ": "gi", "グ": "gu", "ゲ": "ge", "ゴ": "go",
        "ザ": "za", "ジ": "ji", "ズ": "zu", "ゼ": "ze", "ゾ": "zo",
        "ダ": "da", "ヂ": "ji", "ヅ": "zu", "デ": "de", "ド": "do",
        "バ": "ba", "ビ": "bi", "ブ": "bu", "ベ": "be", "ボ": "bo",
        "パ": "pa", "ピ": "pi", "プ": "pu", "ペ": "pe", "ポ": "po",
        "ヴ": "vu",
        "ヰ": "wi", "ヱ": "we",
        "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o",
        "ゃ": "ya", "ゅ": "yu", "ょ": "yo",
        "ゎ": "wa",
        "ァ": "a", "ィ": "i", "ゥ": "u", "ェ": "e", "ォ": "o",
        "ャ": "ya", "ュ": "yu", "ョ": "yo",
        "ヮ": "wa"
    ]

    /// Whether a reading's first mora can take a geminating sokuon — i.e.
    /// `romaji(fromKana:)` on "っ" + `kana` would double a consonant ("って"
    /// geminates, "あ"/"ん"/unmappable don't). Lets the annotator decide
    /// whether a stem-final sokuon merges with the next token or strands as
    /// "tsu". Mirrors `geminatedSokuon`'s accept/reject logic.
    static func geminates(fromKana kana: String) -> Bool {
        let normalized = kana.precomposedStringWithCanonicalMapping
        let chars = Array(normalized)
        guard let first = chars.first else { return false }
        var mora: String?
        if chars.count > 1, let digraph = digraphs[String(chars[0 ... 1])] {
            mora = digraph
        } else {
            mora = singles[String(first)]
        }
        guard let mapped = mora, let onset = mapped.first,
              !"aiueo".contains(onset) else { return false }
        return true
    }

    /// The romaji a sokuon contributes before the mora at `index`, plus the
    /// number of characters consumed: the next mora's leading consonant
    /// doubles ("っか" → "kka", "っち" → "cchi", "っちゃ" → "ccha", "っつ" →
    /// "ttsu", loanword geminates like "ベッド" → "ddo"), and the は/ば/ふ
    /// sounds realize as the p-series ("っぴ" → "ppi", "っぷ" → "ppu").
    /// Returns nil when the next mora can't geminate (vowel-initial,
    /// unmappable, or end of input).
    private static func geminatedSokuon(
        at index: Int, in chars: [Character]
    ) -> (romaji: String, consumed: Int)? {
        guard index + 1 < chars.count else { return nil }
        let next = String(chars[index + 1])
        var mora: String
        var consumed = 1
        if index + 2 < chars.count,
           let digraph = digraphs[next + String(chars[index + 2])]
        {
            mora = digraph
            consumed = 2
        } else if let single = singles[next] {
            mora = single
        } else {
            return nil
        }
        guard let first = mora.first, !"aiueo".contains(first) else { return nil }
        if "hbf".contains(first) {
            return ("pp" + mora.dropFirst(), consumed + 1)
        }
        return (String(first) + mora, consumed + 1)
    }

    /// ん: "n'" before a vowel or y-row (まんいん → "man'in", げんや →
    /// "gen'ya" — the apostrophe keeps the next mora from composing as にゃ),
    /// "n" elsewhere (かんな → "kanna", さん → "san").
    private static func moraicN(after next: Character?) -> String {
        guard let next, let mapped = singles[String(next)], let first = mapped.first,
              "aiueoy".contains(first) else { return "n" }
        return "n'"
    }
}
