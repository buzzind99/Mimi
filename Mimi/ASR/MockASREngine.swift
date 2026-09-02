import Foundation

/// Pure-Swift stand-in used when the native runtime is unavailable. Emits
/// deterministic pseudo transcripts driven by the audio energy (simple RMS
/// threshold) so the
/// full pipeline — buffering, translation, UI, export — stays exercisable.
/// The UI labels mock sessions clearly.
///
/// `@unchecked Sendable`: state is only ever touched from the single capture
/// queue thread (`push`) or the main actor (`poll`/`finish`), which the
/// compiler cannot see — the pipeline contract fences chunks before teardown.
final class MockASREngine: ASREngine, @unchecked Sendable {
    let isMock = true
    var onEngineError: ((String) -> Void)?

    private static let canned = [
        "今日はいい天気ですね。",
        "これから配信を始めます、よろしくお願いします。",
        "新しいゲーム、みんな遊んだ？",
        "チャットの質問に答えていきますね。",
        "次の話題に移ります、面白いですよ。"
    ]

    private var speechChunksSeen = 0
    private var nextSentenceAt = 6
    private var pendingFinal: String?
    private var cannedIndex = 0
    private var totalSamples = 0
    private var lastFinalEnd = 0

    var processedSamples: Int {
        totalSamples
    }

    var pushedSamples: Int {
        totalSamples
    }

    func prepare() throws {}
    func openStream() throws {}

    func push(_ samples: [Float]) {
        totalSamples += samples.count
        var energy: Float = 0
        for s in samples {
            energy += s * s
        }
        let rms = (energy / Float(max(1, samples.count))).squareRoot()
        if rms > 1e-3 {
            speechChunksSeen += 1
        }
        if pendingFinal == nil, speechChunksSeen >= nextSentenceAt {
            pendingFinal = Self.canned[cannedIndex % Self.canned.count]
            cannedIndex += 1
            nextSentenceAt = speechChunksSeen + Int.random(in: 5 ... 12)
        }
    }

    func poll() -> ASREvent? {
        guard let text = pendingFinal else { return nil }
        pendingFinal = nil
        let end = totalSamples
        let start = lastFinalEnd
        lastFinalEnd = end
        return .final(text: text, startSample: start, endSample: end, lang: "ja")
    }

    func finish() -> [ASREvent] {
        // Parity with the real engine: an undelivered pending final is
        // flushed (same span construction as `poll`) and then cleared.
        guard let event = poll() else { return [] }
        return [event]
    }
}
