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

    let config = Config()

    private(set) var nextIndex = 0
    private var text = ""
    private var startSample: Int = 0
    private var lastEndSample: Int = 0
    private var lastAppendAt: Date = .distantPast
    private var isEmpty = true

    var onSentence: ((Sentence) -> Void)?

    var pendingText: String { text }

    /// Append a final ASR piece with its sample span.
    func append(finalText piece: String, startSample: Int, endSample: Int) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isEmpty {
            self.startSample = startSample
            isEmpty = false
        }
        self.text += trimmed
        lastEndSample = endSample
        lastAppendAt = Date()

        if tier1ShouldClose() {
            close()
        } else if self.text.count >= config.maxChars {
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
                    if Array(chars[i..<(i + boundaryChars.count)]) == boundaryChars {
                        cut = i + boundaryChars.count
                        break
                    }
                    i += 1
                }
            }
            if cut != nil { break }
        }
        guard let cut, cut > 0, cut < chars.count else { return }

        let head = String(chars[0..<cut])
        let tail = String(chars[cut...])
        text = head
        emit()
        text = tail
        startSample = lastEndSample
        if tier1ShouldClose() { close() }
    }

    private func close() {
        guard !isEmpty else { return }
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
