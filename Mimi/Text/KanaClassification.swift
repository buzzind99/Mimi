/// Scalar-level kana/kanji classification shared by the reading annotator and
/// the surface↔reading alignment.
enum KanaClassification {
    /// Hiragana and katakana, including the long-vowel mark and small kana.
    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        isHiragana(scalar) || isKatakana(scalar)
    }

    /// Hiragana, including small kana.
    static func isHiragana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041 ... 0x309F).contains(scalar.value)
    }

    /// Katakana, including the long-vowel mark and small kana.
    static func isKatakana(_ scalar: Unicode.Scalar) -> Bool {
        (0x30A1 ... 0x30FF).contains(scalar.value)
    }

    /// Kanji and the iteration mark 々.
    static func isKanji(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00 ... 0x9FFF).contains(scalar.value)
            || (0x3400 ... 0x4DBF).contains(scalar.value)
            || scalar.value == 0x3005
    }

    /// Whether `text` contains any kanji (or 々).
    static func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isKanji)
    }
}
