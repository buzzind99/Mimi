import Foundation

/// Groups ASR finals into translatable sentences and applies the 3-tier
/// boundary policy:
///   1. Terminal punctuation (`。！？`) closes immediately.
///   2. Silence timeout: no new finals for ~1 s finalizes the buffer.
///   3. Length cap (~35–45 chars): split at the nearest clause boundary.
///
/// All calls must happen on one actor/queue (AppModel hops to MainActor).
final class SentenceBuffer {
    struct Config {
        var silenceTimeout: TimeInterval = 1.0
        var maxChars = 42
        var minSplitChars = 18
    }

    /// Terminal punctuation closes the sentence immediately.
    private static let terminal: Set<Character> = ["。", "！", "？", "?", "!"]
    /// Clause-boundary candidates for tier-3 splits, longest match first.
    private static let clauseBoundaries = ["けど", "から", "ので", "って", "、", ","]

    /// True if the string contains at least one "content" character
    /// (kana, kanji, Latin letter, or digit). Punctuation/symbols only
    /// (e.g. "...", "...?") return false.
    private static func hasContent(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040 ... 0x309F, // hiragana
                 0x30A0 ... 0x30FF, // katakana (incl. long-vowel mark ー)
                 0x4E00 ... 0x9FFF, // CJK unified ideographs
                 0x30 ... 0x39: // ASCII digits
                return true
            case 0x41 ... 0x5A, 0x61 ... 0x7A: // Latin letters
                return true
            default:
                return false
            }
        }
    }

    let config = Config()

    private(set) var nextIndex = 0
    private var text = ""
    private var startSample: Int = 0
    private var lastEndSample: Int = 0
    private var lastAppendAt: Date = .distantPast
    private var isEmpty = true

    var onSentence: ((Sentence) -> Void)?

    /// Append a final ASR piece with its sample span.
    func append(finalText piece: String, startSample: Int, endSample: Int) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Drop symbol-only finals (e.g. "...", "...?") when they would
        // start a new sentence; keep them as trailing punctuation when
        // the buffer already has content.
        if isEmpty, !Self.hasContent(trimmed) {
            return
        }
        if isEmpty {
            self.startSample = startSample
            isEmpty = false
        }
        text += trimmed
        lastEndSample = endSample
        lastAppendAt = Date()

        if tier1ShouldClose() {
            close()
        } else if text.count >= config.maxChars {
            splitAtClauseBoundary()
        }
    }

    /// Tier 2: called on a timer; closes the buffer after the silence timeout.
    func tick(now: Date = Date()) {
        guard !isEmpty else { return }
        if now.timeIntervalSince(lastAppendAt) >= config.silenceTimeout {
            close()
        }
    }

    /// Flush any partial buffer (e.g. on session stop).
    func flush() {
        guard !isEmpty else { return }
        close()
    }

    // MARK: - Tiers

    private func tier1ShouldClose() -> Bool {
        guard let last = text.last else { return false }
        return Self.terminal.contains(last)
    }

    /// Tier 3: split at the nearest clause boundary at/after `minSplitChars`.
    private func splitAtClauseBoundary() {
        let chars = Array(text)
        var cut: Int?
        for boundary in Self.clauseBoundaries {
            let boundaryChars = Array(boundary)
            if boundaryChars.count <= chars.count {
                var i = config.minSplitChars
                while i <= chars.count - boundaryChars.count {
                    if Array(chars[i ..< (i + boundaryChars.count)]) == boundaryChars {
                        cut = i + boundaryChars.count
                        break
                    }
                    i += 1
                }
            }
            if cut != nil {
                break
            }
        }
        guard let cut, cut > 0, cut < chars.count else { return }

        let head = String(chars[0 ..< cut])
        let tail = String(chars[cut...])
        text = head
        emit()
        text = tail
        startSample = lastEndSample
        if tier1ShouldClose() {
            close()
        }
    }

    private func close() {
        guard !isEmpty else { return }
        // Never emit a symbol-only sentence (e.g. a split tail that is
        // just punctuation).
        guard Self.hasContent(text) else {
            text = ""
            isEmpty = true
            return
        }
        emit()
    }

    private func emit() {
        let sentence = Sentence(
            index: nextIndex,
            startS: SessionClock.seconds(startSample),
            endS: SessionClock.seconds(max(lastEndSample, startSample)),
            lang: "ja",
            text: text
        )
        nextIndex += 1
        text = ""
        isEmpty = true
        onSentence?(sentence)
    }
}
