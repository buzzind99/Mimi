import Foundation

/// Aligns a dictionary token's surface with its kana reading: the kana in the
/// surface must match the reading kana-for-kana, in order (katakana folded to
/// hiragana), while kanji chunks freely consume the reading kana between
/// their anchors (見た/みた → 見↔み + た↔た). With IPADIC's per-surface
/// readings this succeeds for essentially every annotated token — the
/// property the vibrato migration rests on; a nil result marks a reading
/// that doesn't walk its surface.
enum ReadingAlignment {
    /// One aligned chunk: the surface run and the kana reading it. Kanji
    /// chunks may carry an empty kana run when the reading's split across
    /// consecutive kanji is unknowable (時々 → 時々/ときどき).
    struct Run: Equatable {
        let surface: String
        let kana: String
    }

    /// The aligned runs, or nil when `reading` doesn't walk `surface`: a
    /// surface kana missing from (or out of order in) the reading, leftover
    /// reading kana, or a non-kana character in the reading.
    static func runs(surface: String, reading: String) -> [Run]? {
        let surfaceScalars = Array(
            surface.precomposedStringWithCanonicalMapping.unicodeScalars
        )
        let readingScalars = Array(
            reading.precomposedStringWithCanonicalMapping.unicodeScalars
        )
        guard !surfaceScalars.isEmpty, !readingScalars.isEmpty else { return nil }

        var chunks: [Chunk] = []
        var readingIndex = 0

        for (index, scalar) in surfaceScalars.enumerated() {
            if isKana(scalar) {
                guard readingIndex < readingScalars.count,
                      fold(readingScalars[readingIndex]) == fold(scalar)
                else { return nil }
                append(
                    surface: scalar, kana: [readingScalars[readingIndex]],
                    matched: true, into: &chunks
                )
                readingIndex += 1
            } else if isKanji(scalar) {
                // The kanji consumes the reading up to the next surface kana
                // anchor; a trailing kanji consumes everything left.
                if let anchor = surfaceScalars[(index + 1)...].firstIndex(where: isKana) {
                    let target = fold(surfaceScalars[anchor])
                    guard
                        let match = readingScalars[readingIndex...].firstIndex(where: {
                            fold($0) == target
                        }),
                        consumesKanaOnly(readingScalars[readingIndex ..< match])
                    else { return nil }
                    append(
                        surface: scalar, kana: readingScalars[readingIndex ..< match],
                        matched: false, into: &chunks
                    )
                    readingIndex = match
                } else {
                    guard consumesKanaOnly(readingScalars[readingIndex...]) else {
                        return nil
                    }
                    append(
                        surface: scalar, kana: readingScalars[readingIndex...],
                        matched: false, into: &chunks
                    )
                    readingIndex = readingScalars.count
                }
            } else {
                // Punctuation, Latin, or digits inside a read token: the
                // kana reading can't walk through them.
                return nil
            }
        }
        guard readingIndex == readingScalars.count else { return nil }
        return chunks.map { Run(surface: $0.surface, kana: $0.kana) }
    }

    // MARK: - Internals

    /// A run under construction; `matched` chunks (surface kana mapping to
    /// their own kana) never merge with `consumed` chunks (kanji taking the
    /// reading between anchors), but consecutive same-kind chunks fuse.
    private struct Chunk {
        var surface: String
        var kana: String
        let matched: Bool
    }

    private static func append(
        surface: Unicode.Scalar, kana: some Sequence<Unicode.Scalar>,
        matched: Bool, into chunks: inout [Chunk]
    ) {
        let kanaString = String(String.UnicodeScalarView(kana))
        if var last = chunks.last, last.matched == matched {
            last.surface.append(String(surface))
            last.kana += kanaString
            chunks[chunks.count - 1] = last
        } else {
            chunks.append(
                Chunk(surface: String(surface), kana: kanaString, matched: matched)
            )
        }
    }

    private static func consumesKanaOnly<C: Collection>(
        _ scalars: C
    ) -> Bool where C.Element == Unicode.Scalar {
        scalars.allSatisfy(isKana)
    }

    /// Hiragana and katakana, including the long-vowel mark and small kana.
    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041 ... 0x309F).contains(scalar.value)
            || (0x30A1 ... 0x30FF).contains(scalar.value)
    }

    /// Kanji and the iteration mark 々, which may consume reading kana.
    private static func isKanji(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00 ... 0x9FFF).contains(scalar.value)
            || (0x3400 ... 0x4DBF).contains(scalar.value)
            || scalar.value == 0x3005
    }

    /// Folds katakana onto its hiragana counterpart so katakana surfaces
    /// (ゲーム版) match hiragana readings (げーむばん). Non-katakana scalars
    /// pass through unchanged.
    private static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard (0x30A1 ... 0x30F6).contains(scalar.value) else { return scalar }
        return Unicode.Scalar(scalar.value - 0x60)!
    }
}
